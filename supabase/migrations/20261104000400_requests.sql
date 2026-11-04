-- =====================================================================================
-- Requests: submission (folio + reservation in one transaction), controlled status
-- transitions, physical exit, cancellations, returns.
--
-- Physical deduction event per delivery method:
--   shipping → transition to 'shipped'   (handed to the carrier)
--   pickup   → transition to 'collected' (customer picked it up)
-- =====================================================================================

insert into public.settings (key, value, description) values
  ('max_lines_per_request', '30', 'Maximum different samples in one request'),
  ('rate_limit_per_hour', '5', 'Public submissions allowed per client fingerprint per hour'),
  ('rate_limit_per_email_day', '10', 'Public submissions allowed per email per day'),
  ('allow_requests_on_unvalidated_stock', 'true', 'If false, stock pending physical validation is not offered publicly'),
  ('require_validated_image', 'true', 'If true, the public catalog only lists variants with a validated primary image'),
  ('folio_prefix', '"SMCES"', 'Visible folio prefix (kept from the legacy system)'),
  ('folio_min_digits', '4', 'Zero padding of the folio number (legacy folios use 4 digits: SMCES-0001)'),
  ('pickup_warehouse_address', 'null', 'Pickup address shown to customers (to be provided by CESANTONI/ARMEX)');

create or replace function app.setting(p_key text) returns jsonb language sql stable security definer set search_path = public as $$
  select value from public.settings where key = p_key
$$;

create or replace function app.format_folio(n integer) returns text language sql stable security definer set search_path = public, app as $$
  select (app.setting('folio_prefix') #>> '{}') || '-' || lpad(n::text, greatest((app.setting('folio_min_digits'))::int, length(n::text)), '0')
$$;

-- Moves the folio sequence after the highest folio already in the database (legacy or new).
-- Run at cut-over, after the last legacy folio was imported.
create or replace function public.folio_sequence_sync() returns integer
language plpgsql security definer set search_path = public, app as $$
declare mx integer;
begin
  perform app.require_role('admin', 'service');
  select coalesce(max(folio_number), 0) into mx from public.requests;
  perform setval('public.request_folio_seq', greatest(mx, 1), mx > 0);
  return mx + 1;
end $$;

-- ------------------------------------------------------------------ allowed transitions
create table app.status_transitions (
  from_status app.request_status not null,
  to_status   app.request_status not null,
  roles       text[] not null,
  method      app.delivery_method,         -- NULL = both
  primary key (from_status, to_status)
);
insert into app.status_transitions values
  ('submitted',        'reserved',         '{service}', null),
  ('reserved',         'in_preparation',   '{admin,cesantoni,armex}', null),
  ('in_preparation',   'ready',            '{admin,cesantoni,armex}', null),
  ('ready',            'in_preparation',   '{admin,cesantoni,armex}', null),
  ('ready',            'shipped',          '{admin,cesantoni,armex}', 'shipping'),
  ('ready',            'ready_for_pickup', '{admin,cesantoni,armex}', 'pickup'),
  ('ready_for_pickup', 'collected',        '{admin,cesantoni,armex}', 'pickup'),
  ('shipped',          'delivered',        '{admin,cesantoni,armex,service}', 'shipping');
-- on_hold / cancelled are handled explicitly below

create or replace function app.add_history(p_request_id bigint, p_from app.request_status, p_to app.request_status,
  p_reason text, p_op_id uuid, p_occurred_at timestamptz, p_exception boolean default false)
returns void language sql security definer set search_path = public, app as $$
  insert into public.request_status_history (request_id, from_status, to_status, reason, is_exception, actor, actor_label, op_id, occurred_at)
  values (p_request_id, p_from, p_to, p_reason, p_exception, auth.uid(), app.caller_label(), p_op_id, coalesce(p_occurred_at, now()));
$$;

-- ------------------------------------------------------------------ notifications queue (outbox)
create or replace function app.enqueue_notification(p_event text, p_request_id bigint, p_extra jsonb default '{}'::jsonb, p_suffix text default '')
returns integer language plpgsql security definer set search_path = public, app as $$
declare r public.requests; n integer := 0; rc integer; rcpt record;
  customer_events text[] := array['request_confirmed', 'samples_prepared', 'tracking_registered', 'shipped',
                                  'ready_for_pickup', 'delivered', 'collected', 'cancelled'];
begin
  select * into r from public.requests where id = p_request_id;
  if p_event = any(customer_events) then
    insert into public.notifications (event, request_id, recipient, audience, template, payload, dedupe_key)
    values (p_event, r.id, lower(r.email), 'customer', p_event || '.customer.en', p_extra,
            p_event || ':' || r.id || ':' || lower(r.email) || p_suffix)
    on conflict (dedupe_key) do nothing;
    get diagnostics rc = row_count; n := n + rc;
  end if;
  for rcpt in select nr.email from public.notification_recipients nr where nr.event = p_event and nr.active loop
    insert into public.notifications (event, request_id, recipient, audience, template, payload, dedupe_key)
    values (p_event, r.id, rcpt.email, 'internal', p_event || '.internal.es', p_extra,
            p_event || ':' || r.id || ':' || rcpt.email || p_suffix)
    on conflict (dedupe_key) do nothing;
    get diagnostics rc = row_count; n := n + rc;
  end loop;
  return n;
end $$;

-- ------------------------------------------------------------------ rate limiting
create or replace function app.rate_limit_hit(p_bucket text, p_limit integer, p_window interval) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare w timestamptz := date_bin(p_window, now(), timestamptz '2000-01-01'); h integer;
begin
  insert into app.rate_limits (bucket, window_start, hits) values (p_bucket, w, 1)
  on conflict (bucket, window_start) do update set hits = app.rate_limits.hits + 1
  returning hits into h;
  delete from app.rate_limits where window_start < now() - interval '2 days';
  return h <= p_limit;
end $$;

-- ------------------------------------------------------------------ reserve / release / ship helpers
-- Allocates p_qty of a SKU across its stock rows (most available first), all rows already locked.
create or replace function app.reserve_line(p_request_id bigint, p_line_id bigint, p_sku_id bigint, p_qty integer, p_op_id uuid)
returns void language plpgsql security definer set search_path = public, app as $$
declare s record; take integer; left_ integer := p_qty;
begin
  for s in select id, on_hand - reserved as avail from public.stock
            where sku_id = p_sku_id and on_hand - reserved > 0
              and (coalesce((app.setting('allow_requests_on_unvalidated_stock'))::boolean, true) or validation_status = 'validated')
            order by on_hand - reserved desc, id loop
    exit when left_ = 0;
    take := least(left_, s.avail);
    perform app.stock_change(s.id, 'reserve', 0, take, p_op_id, 'Reservation for request', p_request_id);
    insert into public.reservations (request_id, request_line_id, stock_id, quantity) values (p_request_id, p_line_id, s.id, take);
    left_ := left_ - take;
  end loop;
  if left_ > 0 then
    raise exception 'INSUFFICIENT_AVAILABLE: line % short by %', p_line_id, left_ using errcode = '23514';
  end if;
end $$;

create or replace function app.release_reservations(p_request_id bigint, p_op_id uuid, p_reason text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare rv public.reservations; n integer := 0;
begin
  for rv in select * from public.reservations where request_id = p_request_id and status = 'active' order by stock_id for update loop
    perform app.stock_change(rv.stock_id, 'release', 0, -rv.quantity, p_op_id, p_reason, p_request_id);
    update public.reservations set status = 'released', closed_at = now(), closed_op_id = p_op_id where id = rv.id;
    n := n + rv.quantity;
  end loop;
  return n;
end $$;

-- Physical exit: consumes every active reservation exactly once.
create or replace function app.ship_reservations(p_request_id bigint, p_op_id uuid, p_reason text, p_occurred_at timestamptz)
returns integer language plpgsql security definer set search_path = public, app as $$
declare rv public.reservations; n integer := 0;
begin
  for rv in select * from public.reservations where request_id = p_request_id and status = 'active' order by stock_id for update loop
    perform app.stock_change(rv.stock_id, 'ship', -rv.quantity, -rv.quantity, p_op_id, p_reason, p_request_id, p_occurred_at);
    update public.reservations set status = 'consumed', closed_at = now(), closed_op_id = p_op_id where id = rv.id;
    n := n + rv.quantity;
  end loop;
  return n;
end $$;

-- ------------------------------------------------------------------ public submission
-- Called only by the server (Edge Function, service role) after input validation and anti-abuse checks.
-- p_payload: {full_name, company, email, phone, delivery_method, address_line, city, state, zip_code, country,
--             delivery_notes, project_name, notes, billing, lines:[{sku_code, quantity}]}
-- Either everything is stored (request, lines, reservations, movements, notifications) or nothing.
create or replace function public.submit_request(p_payload jsonb, p_idempotency_key uuid, p_token_hash text, p_fingerprint text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  prev jsonb; req public.requests; ln jsonb; sku record; line_id bigint; i integer := 0; n integer; problems jsonb := '[]'::jsonb;
  max_lines integer := (app.setting('max_lines_per_request'))::int; qty integer; seen bigint[] := '{}';
  allow_unvalidated boolean := coalesce((app.setting('allow_requests_on_unvalidated_stock'))::boolean, true);
  dm app.delivery_method;
begin
  perform app.require_role('service');
  perform set_config('app.actor_label', 'public-web', true);
  prev := app.begin_operation(p_idempotency_key, 'submit_request');
  if prev is not null then return prev - 'tracking_token'; end if;   -- double click / retry: same folio, no second request

  if p_token_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid token hash' using errcode = '22023'; end if;
  begin dm := (p_payload ->> 'delivery_method')::app.delivery_method;
  exception when others then raise exception 'VALIDATION: delivery_method must be shipping or pickup' using errcode = '22023'; end;

  -- anti-abuse
  if p_fingerprint is not null and not app.rate_limit_hit('fp:' || p_fingerprint, (app.setting('rate_limit_per_hour'))::int, interval '1 hour') then
    raise exception 'RATE_LIMITED' using errcode = '53400';
  end if;
  if not app.rate_limit_hit('email:' || lower(p_payload ->> 'email'), (app.setting('rate_limit_per_email_day'))::int, interval '1 day') then
    raise exception 'RATE_LIMITED' using errcode = '53400';
  end if;

  n := jsonb_array_length(coalesce(p_payload -> 'lines', '[]'::jsonb));
  if n = 0 then raise exception 'VALIDATION: select at least one sample' using errcode = '22023'; end if;
  if n > max_lines then raise exception 'VALIDATION: maximum % different samples per request', max_lines using errcode = '22023'; end if;

  -- lock every candidate stock row in a stable order (prevents deadlocks and double allocation)
  perform 1 from public.stock s join public.sample_skus k on k.id = s.sku_id
   where k.code in (select upper(btrim(x ->> 'sku_code')) from jsonb_array_elements(p_payload -> 'lines') x)
   order by s.id for update of s;

  -- re-check availability and limits on the server
  for ln in select * from jsonb_array_elements(p_payload -> 'lines') loop
    qty := case when (ln ->> 'quantity') ~ '^[0-9]{1,4}$' then (ln ->> 'quantity')::int else 0 end;
    select k.id, k.code, k.max_per_request, k.public_enabled, k.catalog_verified, k.status,
           coalesce(sum(s.on_hand - s.reserved) filter (where allow_unvalidated or s.validation_status = 'validated'), 0)::int as available
      into sku
      from public.sample_skus k left join public.stock s on s.sku_id = k.id
     where k.code = upper(btrim(ln ->> 'sku_code'))
     group by k.id;
    if sku.id is null or not sku.public_enabled or not sku.catalog_verified or sku.status <> 'active' then
      problems := problems || jsonb_build_object('sku_code', ln ->> 'sku_code', 'problem', 'not_available', 'available', 0);
    elsif sku.id = any(seen) then
      problems := problems || jsonb_build_object('sku_code', sku.code, 'problem', 'duplicated');
    elsif qty < 1 or qty > sku.max_per_request then
      problems := problems || jsonb_build_object('sku_code', sku.code, 'problem', 'quantity_limit', 'max', sku.max_per_request);
    elsif qty > sku.available then
      problems := problems || jsonb_build_object('sku_code', sku.code, 'problem', 'insufficient', 'available', sku.available);
    end if;
    seen := seen || sku.id;
  end loop;
  if jsonb_array_length(problems) > 0 then
    raise exception 'UNAVAILABLE' using errcode = 'P0001', detail = problems::text;
  end if;

  -- folio from a sequence: unique under concurrency (never computed from max()+1 or in the browser)
  insert into public.requests (folio_number, folio, status, full_name, company, email, phone, delivery_method,
      address_line, city, state, zip_code, country, delivery_notes, project_name, notes, billing,
      tracking_token_hash, idempotency_key, client_fingerprint)
  select x.n, app.format_folio(x.n), 'submitted',
      btrim(p_payload ->> 'full_name'), nullif(btrim(p_payload ->> 'company'), ''), lower(btrim(p_payload ->> 'email')),
      btrim(p_payload ->> 'phone'), dm,
      case when dm = 'shipping' then nullif(btrim(p_payload ->> 'address_line'), '') end,
      case when dm = 'shipping' then nullif(btrim(p_payload ->> 'city'), '') end,
      case when dm = 'shipping' then nullif(btrim(p_payload ->> 'state'), '') end,
      case when dm = 'shipping' then nullif(btrim(p_payload ->> 'zip_code'), '') end,
      case when dm = 'shipping' then nullif(btrim(p_payload ->> 'country'), '') end,
      nullif(btrim(p_payload ->> 'delivery_notes'), ''), nullif(btrim(p_payload ->> 'project_name'), ''),
      nullif(btrim(p_payload ->> 'notes'), ''), case when jsonb_typeof(p_payload -> 'billing') = 'object' then p_payload -> 'billing' end,
      p_token_hash, p_idempotency_key, p_fingerprint
  from (select nextval('public.request_folio_seq')::int as n) x
  returning * into req;
  perform app.add_history(req.id, null, 'submitted', 'Submitted from the public request form', p_idempotency_key, req.created_at);

  for ln in select * from jsonb_array_elements(p_payload -> 'lines') loop
    i := i + 1;
    select k.id, k.code, k.sample_type, k.sample_size, k.sample_size_en, p.model, p.display_name_en, v.color_source, v.color_en,
           f.code as finish_code, f.name_en as finish_en
      into sku
      from public.sample_skus k join public.variants v on v.id = k.variant_id join public.products p on p.id = v.product_id
      join public.finishes f on f.code = v.finish_code
     where k.code = upper(btrim(ln ->> 'sku_code'));
    insert into public.request_lines (request_id, line_no, sku_id, quantity, snap_model, snap_color, snap_finish,
        snap_sample_size, snap_sample_type, snap_description)
    values (req.id, i, sku.id, (ln ->> 'quantity')::int, sku.model, coalesce(sku.color_en, sku.color_source), sku.finish_en,
        sku.sample_size_en, sku.sample_type::text,
        concat_ws(' · ', sku.display_name_en, coalesce(sku.color_en, sku.color_source), sku.finish_en, sku.sample_size_en))
    returning id into line_id;
    perform app.reserve_line(req.id, line_id, sku.id, (ln ->> 'quantity')::int, p_idempotency_key);
  end loop;

  update public.requests set status = 'reserved' where id = req.id;
  perform app.add_history(req.id, 'submitted', 'reserved', 'Pieces reserved automatically', p_idempotency_key, now());
  perform app.enqueue_notification('request_confirmed', req.id);

  return app.finish_operation(p_idempotency_key, jsonb_build_object('status', 'created', 'request_id', req.id, 'folio', req.folio));
end $$;

-- ------------------------------------------------------------------ status changes
create or replace function public.request_set_status(p_op_id uuid, p_request_id bigint, p_to app.request_status,
  p_reason text default null, p_occurred_at timestamptz default null, p_exception boolean default false)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; r public.requests; role text := app.caller_role(); tr app.status_transitions; missing text[] := '{}';
  qty integer; back app.request_status; line record;
begin
  perform app.require_role('admin', 'cesantoni', 'armex', 'service');
  prev := app.begin_operation(p_op_id, 'request_set_status'); if prev is not null then return prev; end if;
  select * into r from public.requests where id = p_request_id for update;
  if not found then raise exception 'request % not found', p_request_id using errcode = 'P0002'; end if;
  if p_occurred_at is not null and p_occurred_at > now() + interval '5 minutes' then
    raise exception 'event date cannot be in the future' using errcode = '22023';
  end if;
  if p_exception then
    perform app.require_role('admin');
    perform app.require_reason(p_reason);
  end if;

  -- ---------------- cancellation
  if p_to = 'cancelled' then
    perform app.require_role('admin', 'cesantoni');
    perform app.require_reason(p_reason);
    if r.status in ('cancelled', 'delivered', 'collected') then
      raise exception 'INVALID_TRANSITION: % cannot be cancelled', r.status using errcode = '22023';
    end if;
    -- before the exit: reservations go back to available. After the exit: nothing is restocked automatically.
    qty := app.release_reservations(r.id, p_op_id, 'Cancellation: ' || p_reason);
    update public.requests set status = 'cancelled' where id = r.id;
    perform app.add_history(r.id, r.status, 'cancelled', p_reason, p_op_id, p_occurred_at, p_exception);
    perform app.enqueue_notification('cancelled', r.id);
    return app.finish_operation(p_op_id, jsonb_build_object('status', 'cancelled', 'released', qty));
  end if;

  -- ---------------- hold / resume
  if p_to = 'on_hold' then
    perform app.require_role('admin', 'cesantoni', 'armex');
    perform app.require_reason(p_reason);
    if r.status in ('on_hold', 'cancelled', 'delivered', 'collected', 'shipped') then
      raise exception 'INVALID_TRANSITION: % cannot be put on hold', r.status using errcode = '22023';
    end if;
    update public.requests set status = 'on_hold' where id = r.id;
    perform app.add_history(r.id, r.status, 'on_hold', p_reason, p_op_id, p_occurred_at, p_exception);
    perform app.enqueue_notification('incident', r.id, jsonb_build_object('reason', p_reason), ':hold:' || p_op_id);
    return app.finish_operation(p_op_id, jsonb_build_object('status', 'on_hold'));
  end if;
  if r.status = 'on_hold' then
    select h.from_status into back from public.request_status_history h
     where h.request_id = r.id and h.to_status = 'on_hold' order by h.id desc limit 1;
    if p_to <> back then
      raise exception 'INVALID_TRANSITION: an on-hold request resumes to its previous status (%)', back using errcode = '22023';
    end if;
    update public.requests set status = back where id = r.id;
    perform app.add_history(r.id, 'on_hold', back, coalesce(p_reason, 'Resumed'), p_op_id, p_occurred_at, p_exception);
    return app.finish_operation(p_op_id, jsonb_build_object('status', back::text));
  end if;

  -- ---------------- regular flow
  select * into tr from app.status_transitions where from_status = r.status and to_status = p_to;
  if not found then
    raise exception 'INVALID_TRANSITION: % → % is not allowed', r.status, p_to using errcode = '22023';
  end if;
  if not (role = any(tr.roles)) and not (p_exception and role = 'admin') then
    raise exception 'permission denied: role % cannot move % → %', role, r.status, p_to using errcode = '42501';
  end if;
  if tr.method is not null and tr.method <> r.delivery_method then
    raise exception 'INVALID_TRANSITION: % only applies to % requests', p_to, tr.method using errcode = '22023';
  end if;

  -- mandatory steps (an administrator may override them as a documented exception)
  if p_to = 'ready' then
    for line in select l.id, l.line_no, l.quantity, coalesce(sum(pi.quantity) filter (where not pk.voided), 0) as packed
                  from public.request_lines l
                  left join public.package_items pi on pi.request_line_id = l.id
                  left join public.packages pk on pk.id = pi.package_id and pk.kind = 'master'
                 where l.request_id = r.id group by l.id loop
      if line.packed <> line.quantity then missing := missing || format('line %s packed %s of %s', line.line_no, line.packed, line.quantity); end if;
    end loop;
  elsif p_to = 'shipped' then
    if not exists (select 1 from public.shipments where request_id = r.id and status <> 'void') then
      missing := missing || 'carrier and tracking number'::text;
    end if;
  elsif p_to = 'collected' then
    if not exists (select 1 from public.evidences where request_id = r.id and kind = 'pickup_proof' and not voided) then
      missing := missing || 'pickup proof evidence'::text;
    end if;
  elsif p_to = 'delivered' then
    if not exists (select 1 from public.shipments where request_id = r.id and status <> 'void') then
      missing := missing || 'shipment'::text;
    end if;
  end if;
  if array_length(missing, 1) > 0 and not p_exception then
    raise exception 'MISSING_STEPS: %', array_to_string(missing, '; ') using errcode = '23514';
  end if;

  -- physical exit happens exactly once, at the event that matches the delivery method
  if p_to in ('shipped', 'collected') then
    qty := app.ship_reservations(r.id, p_op_id, case when p_to = 'shipped' then 'Handed to carrier' else 'Collected by customer' end, p_occurred_at);
    if p_to = 'shipped' then
      update public.shipments set handed_over_at = coalesce(handed_over_at, coalesce(p_occurred_at, now())), status = 'in_transit'
       where request_id = r.id and status = 'label_created';
    end if;
  end if;
  if p_to = 'delivered' then
    update public.shipments set delivered_at = coalesce(delivered_at, coalesce(p_occurred_at, now())), status = 'delivered'
     where request_id = r.id and status in ('label_created', 'in_transit');
  end if;

  update public.requests set status = p_to where id = r.id;
  perform app.add_history(r.id, r.status, p_to, p_reason, p_op_id, p_occurred_at, p_exception and array_length(missing, 1) > 0);
  perform app.enqueue_notification(case p_to when 'ready' then 'samples_prepared' else p_to::text end, r.id);
  return app.finish_operation(p_op_id, jsonb_build_object('status', p_to::text, 'shipped_pieces', qty,
    'exception_for', to_jsonb(missing)));
end $$;

-- ------------------------------------------------------------------ returns (only with confirmed reception & condition)
create or replace function public.inv_return_receipt(p_op_id uuid, p_request_line_id bigint, p_stock_id bigint, p_quantity integer,
  p_condition_ok boolean, p_reason text, p_received_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; l public.request_lines; shipped integer; returned integer; mv public.inventory_movements;
begin
  perform app.require_role('admin', 'cesantoni');
  prev := app.begin_operation(p_op_id, 'inv_return_receipt'); if prev is not null then return prev; end if;
  if p_received_at is null then raise exception 'reception date is required: returns are registered only once received' using errcode = '22023'; end if;
  if p_condition_ok is not true then
    return app.finish_operation(p_op_id, jsonb_build_object('status', 'not_restocked', 'message', 'Condition not confirmed: pieces are not added to stock.'));
  end if;
  select * into l from public.request_lines where id = p_request_line_id;
  if not found then raise exception 'request line not found' using errcode = 'P0002'; end if;
  select coalesce(sum(r.quantity), 0) into shipped from public.reservations r where r.request_line_id = l.id and r.status = 'consumed';
  select coalesce(sum(m.quantity), 0) into returned from public.inventory_movements m
   join public.stock s on s.id = m.stock_id
   where m.movement = 'return_receipt' and m.request_id = l.request_id and s.sku_id = l.sku_id;
  if p_quantity <= 0 or returned + p_quantity > shipped then
    raise exception 'RETURN_EXCEEDS_SHIPPED: shipped %, already returned %', shipped, returned using errcode = '23514';
  end if;
  if not exists (select 1 from public.stock where id = p_stock_id and sku_id = l.sku_id) then
    raise exception 'stock row does not belong to the returned SKU' using errcode = '22023';
  end if;
  mv := app.stock_change(p_stock_id, 'return_receipt', p_quantity, 0, p_op_id, app.require_reason(p_reason), l.request_id, p_received_at);
  return app.finish_operation(p_op_id, jsonb_build_object('status', 'restocked', 'movement_id', mv.id));
end $$;

grant execute on function public.request_set_status(uuid, bigint, app.request_status, text, timestamptz, boolean),
  public.inv_return_receipt(uuid, bigint, bigint, integer, boolean, text, timestamptz), public.folio_sequence_sync()
to authenticated;
grant execute on function public.submit_request(jsonb, uuid, text, text) to service_role;
