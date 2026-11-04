-- PASO 3 · Pegar en Supabase › SQL Editor › Run (una sola vez, después de 01 y 02).
-- =====================================================================================
-- Public submission directly from the website (no Edge Function or secrets to configure).
-- public.submit_request_public is the ONLY write the anonymous role can call. It:
--   * rejects bots (hidden field, minimum fill time) and validates every field
--   * rate-limits by hashed IP (from the request headers), by email and globally
--   * derives the tracking token from the idempotency key with a secret kept in the database
--     (a retried submission gets the same link; only the token's SHA-256 is stored)
--   * calls the same transactional submit_request (folio + reservation + notifications)
-- =====================================================================================

create table if not exists app.secrets (
  key   text primary key,
  value text not null
);
revoke all on app.secrets from public, anon, authenticated;
insert into app.secrets (key, value)
values ('tracking', encode(extensions.gen_random_bytes(32), 'hex')),
       ('fingerprint', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

create or replace function app.tracking_token(p_idempotency_key uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select left(encode(extensions.hmac('track:' || p_idempotency_key::text,
                     (select value from app.secrets where key = 'tracking'), 'sha256'), 'hex'), 48)
$$;

-- submit_request accepts a trusted in-database caller (the public wrapper below) besides the server role
create or replace function app.trusted_submit() returns boolean language sql stable as $$
  select coalesce(current_setting('app.trusted_submit', true), '') = 'on'
$$;

do $$
declare src text;
begin
  select pg_get_functiondef('public.submit_request(jsonb, uuid, text, text)'::regprocedure) into src;
  if position('app.trusted_submit()' in src) = 0 then
    src := replace(src, 'perform app.require_role(''service'');',
                        'if not app.trusted_submit() then perform app.require_role(''service''); end if;');
    execute src;
  end if;
end $$;

create or replace function public.submit_request_public(p_payload jsonb, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, app as $$
declare
  e jsonb := '{}'::jsonb; dm text := p_payload ->> 'delivery_method'; started bigint; token text; out jsonb;
  headers jsonb; ip text; fp text; clean jsonb;
begin
  if p_idempotency_key is null then raise exception 'VALIDATION: missing request key' using errcode = '22023'; end if;
  -- anti-bot
  if coalesce(p_payload ->> 'website', '') <> '' then raise exception 'VALIDATION: please review the form' using errcode = '22023'; end if;
  begin started := (p_payload ->> 'form_started_at')::bigint; exception when others then started := null; end;
  if started is null or extract(epoch from now()) * 1000 - started < 3000 then
    raise exception 'VALIDATION: please review the form and submit it again' using errcode = '22023';
  end if;
  -- field validation (English messages are shown to the customer)
  if length(btrim(coalesce(p_payload ->> 'full_name', ''))) < 2 then e := e || '{"full_name":"Please enter your full name."}'; end if;
  if coalesce(p_payload ->> 'email', '') !~* '^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]{2,}$' then e := e || '{"email":"Please enter a valid email address."}'; end if;
  if length(regexp_replace(coalesce(p_payload ->> 'phone', ''), '\D', '', 'g')) < 7 then e := e || '{"phone":"Please enter a valid phone number."}'; end if;
  if dm not in ('shipping', 'pickup') or dm is null then e := e || '{"delivery_method":"Choose shipping or customer pickup."}'; end if;
  if dm = 'shipping' then
    if coalesce(btrim(p_payload ->> 'address_line'), '') = '' then e := e || '{"address_line":"Please enter the shipping address."}'; end if;
    if coalesce(btrim(p_payload ->> 'city'), '') = '' then e := e || '{"city":"Please enter the city."}'; end if;
    if coalesce(btrim(p_payload ->> 'state'), '') = '' then e := e || '{"state":"Please enter the state."}'; end if;
    if coalesce(btrim(p_payload ->> 'zip_code'), '') = '' then e := e || '{"zip_code":"Please enter the ZIP code."}'; end if;
    if coalesce(btrim(p_payload ->> 'country'), '') = '' then e := e || '{"country":"Please enter the country."}'; end if;
  end if;
  if jsonb_typeof(p_payload -> 'billing') = 'object' and coalesce(btrim(p_payload -> 'billing' ->> 'company'), '') = '' then
    e := e || '{"billing.company":"Please enter the billing company."}';
  end if;
  if jsonb_typeof(p_payload -> 'lines') <> 'array' or jsonb_array_length(p_payload -> 'lines') = 0 then
    e := e || '{"lines":"Please select at least one sample."}';
  end if;
  if e <> '{}'::jsonb then
    raise exception 'VALIDATION' using errcode = '22023', detail = e::text;
  end if;
  -- only known fields, trimmed to safe lengths
  clean := jsonb_strip_nulls(jsonb_build_object(
    'full_name', left(btrim(p_payload ->> 'full_name'), 120), 'company', left(nullif(btrim(p_payload ->> 'company'), ''), 120),
    'email', left(lower(btrim(p_payload ->> 'email')), 160), 'phone', left(btrim(p_payload ->> 'phone'), 40), 'delivery_method', dm,
    'address_line', left(p_payload ->> 'address_line', 200), 'city', left(p_payload ->> 'city', 80), 'state', left(p_payload ->> 'state', 80),
    'zip_code', left(p_payload ->> 'zip_code', 20), 'country', left(p_payload ->> 'country', 80),
    'delivery_notes', left(p_payload ->> 'delivery_notes', 300), 'project_name', left(p_payload ->> 'project_name', 120),
    'notes', left(p_payload ->> 'notes', 1000),
    'billing', case when jsonb_typeof(p_payload -> 'billing') = 'object' then jsonb_build_object(
        'company', left(p_payload -> 'billing' ->> 'company', 160), 'tax_id', left(p_payload -> 'billing' ->> 'tax_id', 40),
        'address', left(p_payload -> 'billing' ->> 'address', 300), 'email', left(p_payload -> 'billing' ->> 'email', 160)) end,
    'lines', p_payload -> 'lines'));

  -- abuse protection: hashed client IP (never stored raw), plus a global ceiling
  begin headers := current_setting('request.headers', true)::jsonb; exception when others then headers := null; end;
  ip := split_part(coalesce(headers ->> 'cf-connecting-ip', headers ->> 'x-real-ip', headers ->> 'x-forwarded-for', ''), ',', 1);
  fp := case when ip <> '' then left(encode(extensions.hmac(ip || ':' || current_date::text,
               (select value from app.secrets where key = 'fingerprint'), 'sha256'), 'hex'), 32) end;
  if not app.rate_limit_hit('global', 200, interval '1 hour') then raise exception 'RATE_LIMITED' using errcode = '53400'; end if;

  token := app.tracking_token(p_idempotency_key);
  perform set_config('app.trusted_submit', 'on', true);
  out := public.submit_request(clean, p_idempotency_key, encode(extensions.digest(token, 'sha256'), 'hex'), fp);
  perform set_config('app.trusted_submit', '', true);
  return jsonb_build_object('folio', out ->> 'folio', 'track_token', token);
end $$;

revoke all on function public.submit_request_public(jsonb, uuid) from public;
grant execute on function public.submit_request_public(jsonb, uuid) to anon, authenticated;

-- the email worker receives the customer's tracking token (computed in the database, never stored)
create or replace function public.notification_track_token(p_folio text) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_role('service');
  return (select app.tracking_token(r.idempotency_key) from public.requests r where r.folio = p_folio and r.source = 'web');
end $$;
revoke all on function public.notification_track_token(text) from public;
grant execute on function public.notification_track_token(text) to service_role;
