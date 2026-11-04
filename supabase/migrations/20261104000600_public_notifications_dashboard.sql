-- =====================================================================================
-- Public API (catalog, tracking), notification outbox processing, dashboard, storage.
-- =====================================================================================

-- ------------------------------------------------------------------ public catalog
-- Only enabled, verified, active combinations with available pieces (and, by default, a validated photo).
create or replace function public.catalog_items()
returns table (sku_code text, model text, product_name text, category app.product_category, color text, finish text,
               sample_type app.sample_type, sample_size text, max_selectable integer, image_path text, image_kind text)
language sql stable security definer set search_path = public, app as $$
  with avail as (
    select s.sku_id, sum(s.on_hand - s.reserved)::int as available
      from public.stock s
     where coalesce((app.setting('allow_requests_on_unvalidated_stock'))::boolean, true) or s.validation_status = 'validated'
     group by s.sku_id)
  select k.code, p.model, p.display_name_en, p.category, v.color_en, f.name_en, k.sample_type, k.sample_size_en,
         least(k.max_per_request, a.available), img.storage_path, img.kind
    from public.sample_skus k
    join avail a on a.sku_id = k.id and a.available > 0
    join public.variants v on v.id = k.variant_id and v.status = 'active'
    join public.products p on p.id = v.product_id and p.status = 'active'
    join public.finishes f on f.code = v.finish_code
    left join public.variant_images img on img.variant_id = v.id and img.is_primary and img.validated
   where k.public_enabled and k.catalog_verified and k.status = 'active'
     and (img.id is not null or not coalesce((app.setting('require_validated_image'))::boolean, true))
   order by p.display_name_en, v.color_en nulls first, f.name_en, k.sample_type, k.sample_size_en
$$;

-- ------------------------------------------------------------------ public tracking (folio + secret token from the email link)
create or replace function public.track_request(p_folio text, p_token text)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare r public.requests;
begin
  select * into r from public.requests
   where folio = upper(btrim(p_folio)) and tracking_token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found then
    -- same answer for "wrong folio" and "wrong token": nothing can be learned by guessing folios
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'folio', r.folio, 'status', r.status, 'submitted_at', r.created_at, 'delivery_method', r.delivery_method,
    'destination', case when r.delivery_method = 'shipping' then concat_ws(', ', r.city, r.state, r.country) end,
    'lines', (select jsonb_agg(jsonb_build_object('description', l.snap_description, 'quantity', l.quantity) order by l.line_no)
                from public.request_lines l where l.request_id = r.id),
    'history', (select jsonb_agg(jsonb_build_object('status', h.to_status, 'at', h.occurred_at) order by h.occurred_at, h.id)
                  from public.request_status_history h where h.request_id = r.id and h.to_status is distinct from h.from_status),
    'shipments', (select coalesce(jsonb_agg(jsonb_build_object('carrier', s.carrier, 'tracking_no', s.tracking_no,
                       'shipped_at', s.handed_over_at, 'delivered_at', s.delivered_at)), '[]'::jsonb)
                    from public.shipments s where s.request_id = r.id and s.status <> 'void'));
end $$;

grant execute on function public.catalog_items(), public.track_request(text, text) to anon, authenticated;

-- ------------------------------------------------------------------ notification worker (called by the server every minute)
create or replace function public.notifications_claim(p_batch integer default 20)
returns setof jsonb language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_role('service');
  return query
  with due as (
    select id from public.notifications
     where (status in ('pending', 'failed') and next_attempt_at <= now() and attempts < max_attempts)
        or (status = 'sending' and locked_until < now() and attempts < max_attempts)   -- worker died mid-send
     order by next_attempt_at, id
     limit p_batch
     for update skip locked)
  update public.notifications n
     set status = 'sending', attempts = n.attempts + 1, locked_until = now() + interval '2 minutes'
    from due where n.id = due.id
  returning jsonb_build_object('id', n.id, 'event', n.event, 'recipient', n.recipient, 'audience', n.audience,
           'template', n.template, 'payload', n.payload, 'dedupe_key', n.dedupe_key, 'attempt', n.attempts,
           'request', (select jsonb_build_object('folio', r.folio, 'idempotency_key', r.idempotency_key, 'source', r.source, 'full_name', r.full_name, 'company', r.company,
                         'status', r.status, 'delivery_method', r.delivery_method,
                         'lines', (select jsonb_agg(jsonb_build_object('description', l.snap_description, 'quantity', l.quantity) order by l.line_no)
                                     from public.request_lines l where l.request_id = r.id),
                         'shipments', (select coalesce(jsonb_agg(jsonb_build_object('carrier', s.carrier, 'tracking_no', s.tracking_no)), '[]'::jsonb)
                                         from public.shipments s where s.request_id = r.id and s.status <> 'void'))
                       from public.requests r where r.id = n.request_id));
end $$;

-- "accepted" = the provider took the message. "delivered" only comes from the provider's webhook.
create or replace function public.notifications_result(p_id bigint, p_ok boolean, p_provider_id text default null, p_error text default null)
returns void language plpgsql security definer set search_path = public, app as $$
declare n public.notifications;
begin
  perform app.require_role('service');
  select * into n from public.notifications where id = p_id for update;
  if p_ok then
    update public.notifications set status = 'accepted', provider_id = p_provider_id, accepted_at = now(), last_error = null, locked_until = null
     where id = p_id;
  else
    update public.notifications
       set status = 'failed', last_error = left(p_error, 1000), locked_until = null,
           next_attempt_at = now() + (interval '1 minute' * power(2, least(n.attempts, 8)))
     where id = p_id;
  end if;
end $$;

create or replace function public.notifications_provider_event(p_provider_id text, p_event text, p_detail text default null)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_role('service');
  update public.notifications
     set status = case p_event when 'delivered' then 'delivered'::app.notification_status
                               when 'bounced' then 'bounced'::app.notification_status
                               when 'complained' then 'bounced'::app.notification_status else status end,
         delivered_at = case when p_event = 'delivered' then now() else delivered_at end,
         last_error = case when p_event in ('bounced', 'complained') then left(p_detail, 1000) else last_error end
   where provider_id = p_provider_id;
end $$;

create or replace function public.notifications_retry(p_id bigint)
returns void language plpgsql security definer set search_path = public, app as $$
begin
  perform app.require_role('admin', 'cesantoni');
  update public.notifications set status = 'pending', next_attempt_at = now(), max_attempts = attempts + 3
   where id = p_id and status in ('failed', 'bounced');
end $$;

create view public.notification_health with (security_invoker = true) as
select count(*) filter (where status in ('pending', 'failed', 'sending') and created_at < now() - interval '2 minutes') as delayed,
       count(*) filter (where status = 'failed' and attempts >= max_attempts) as failed_final,
       count(*) filter (where status = 'bounced') as bounced,
       count(*) filter (where status = 'accepted') as accepted_not_confirmed,
       count(*) filter (where status = 'delivered') as delivered,
       max(now() - created_at) filter (where status in ('pending', 'failed', 'sending')) as oldest_waiting
  from public.notifications;
grant select on public.notification_health to authenticated;

grant execute on function public.notifications_claim(integer), public.notifications_result(bigint, boolean, text, text),
  public.notifications_provider_event(text, text, text) to service_role;
grant execute on function public.notifications_retry(bigint) to authenticated;

-- ------------------------------------------------------------------ dashboard (every metric has one definition)
create or replace function public.dashboard_metrics(p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.require_role('admin', 'cesantoni', 'armex', 'billing');
  return jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    -- requests created in the period
    'requests_received', (select count(*) from public.requests where created_at >= p_from and created_at < p_to),
    -- current backlog (not limited to the period)
    'pending_preparation', (select count(*) from public.requests where status in ('reserved', 'in_preparation')),
    'ready', (select count(*) from public.requests where status in ('ready', 'ready_for_pickup')),
    -- transitions that happened in the period (by event date)
    'shipped', (select count(distinct request_id) from public.request_status_history where to_status = 'shipped' and occurred_at >= p_from and occurred_at < p_to),
    'delivered_or_collected', (select count(distinct request_id) from public.request_status_history where to_status in ('delivered', 'collected') and occurred_at >= p_from and occurred_at < p_to),
    'open_incidents', (select count(*) from public.incidents where status in ('open', 'in_progress')),
    -- pieces (all sample SKUs; pieces of different sizes are counted separately by type)
    'stock_by_type', (select jsonb_object_agg(t, x) from (
        select k.sample_type::text as t, jsonb_build_object('on_hand', sum(s.on_hand), 'reserved', sum(s.reserved), 'available', sum(s.on_hand - s.reserved)) as x
          from public.stock s join public.sample_skus k on k.id = s.sku_id group by k.sample_type) q),
    'skus_pending_validation', (select count(distinct sku_id) from public.stock where validation_status = 'pending_physical_validation'),
    'skus_out_of_stock', (select count(*) from (select sku_id from public.stock group by sku_id having sum(on_hand - reserved) = 0) q),
    'skus_low_stock', (select count(*) from (select s.sku_id from public.stock s join public.sample_skus k on k.id = s.sku_id
                          group by s.sku_id, k.max_per_request having sum(s.on_hand - s.reserved) between 1 and k.max_per_request) q),
    'shipping_cost_usd', (select coalesce(sum(cost_usd), 0) from public.shipments where status <> 'void' and coalesce(handed_over_at, created_at) >= p_from and coalesce(handed_over_at, created_at) < p_to),
    'shipments_without_cost', (select count(*) from public.shipments where status <> 'void' and cost_usd is null),
    'invoices_pending', (select count(*) from public.invoices where status in ('registered', 'pending_review')),
    'notifications_failed', (select count(*) from public.notifications where status in ('failed', 'bounced')),
    'notifications_delayed', (select delayed from public.notification_health)
  );
end $$;
grant execute on function public.dashboard_metrics(timestamptz, timestamptz) to authenticated;

-- ------------------------------------------------------------------ storage buckets & policies
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('evidence', 'evidence', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf']),
  ('invoices', 'invoices', false, 15728640, array['application/pdf', 'application/xml', 'text/xml']),
  ('catalog-images', 'catalog-images', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy evidence_read on storage.objects for select to authenticated
  using (bucket_id = 'evidence' and app.has_role('admin', 'cesantoni', 'armex'));
create policy evidence_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'evidence' and app.has_role('admin', 'cesantoni', 'armex'));
create policy invoices_read on storage.objects for select to authenticated
  using (bucket_id = 'invoices' and app.has_role('admin', 'cesantoni', 'billing'));
create policy invoices_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'invoices' and app.has_role('admin', 'billing'));
create policy catalog_images_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'catalog-images' and app.has_role('admin', 'cesantoni'));
-- no UPDATE/DELETE policies: stored files cannot be overwritten or removed from the browser
