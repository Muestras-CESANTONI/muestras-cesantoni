-- =====================================================================================
-- ARMEX operation (packages Master/JR, QR scan, shipments, evidence, incidents),
-- billing and user administration.
-- Model (to be confirmed with ARMEX): a MASTER card identifies a box of a request
-- ("bulto" n of N); a JR card identifies one product line inside that box.
-- =====================================================================================

-- ------------------------------------------------------------------ packages
-- p_items: [{"request_line_id": 10, "quantity": 4}, …]  → one Master + one JR per line
create or replace function public.package_create(p_op_id uuid, p_request_id bigint, p_items jsonb, p_prep_location text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; r public.requests; m_id bigint; m_seq int; m_code text; it jsonb; l public.request_lines; packed int; j int := 0; jr_id bigint;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'package_create'); if prev is not null then return prev; end if;
  select * into r from public.requests where id = p_request_id for update;
  if r.status not in ('reserved', 'in_preparation') then
    raise exception 'INVALID_STATE: packages are created while the request is reserved or in preparation (now %)', r.status using errcode = '22023';
  end if;
  if r.status = 'reserved' then
    update public.requests set status = 'in_preparation' where id = r.id;
    perform app.add_history(r.id, 'reserved', 'in_preparation', 'Packing started', p_op_id, now());
  end if;
  select coalesce(max(seq), 0) + 1 into m_seq from public.packages where request_id = r.id and kind = 'master';
  m_code := r.folio || '-M' || lpad(m_seq::text, 2, '0');
  insert into public.packages (request_id, kind, code, seq, prep_location, created_by)
  values (r.id, 'master', m_code, m_seq, p_prep_location, auth.uid()) returning id into m_id;

  for it in select * from jsonb_array_elements(p_items) loop
    select * into l from public.request_lines where id = (it ->> 'request_line_id')::bigint and request_id = r.id;
    if not found then raise exception 'line % does not belong to %', it ->> 'request_line_id', r.folio using errcode = '22023'; end if;
    select coalesce(sum(pi.quantity), 0) into packed from public.package_items pi join public.packages p on p.id = pi.package_id
     where pi.request_line_id = l.id and p.kind = 'master' and not p.voided;
    if (it ->> 'quantity')::int <= 0 or packed + (it ->> 'quantity')::int > l.quantity then
      raise exception 'PACK_EXCEEDS_LINE: line % has % requested, % already packed', l.line_no, l.quantity, packed using errcode = '23514';
    end if;
    insert into public.package_items (package_id, request_line_id, quantity) values (m_id, l.id, (it ->> 'quantity')::int);
    j := j + 1;
    insert into public.packages (request_id, kind, parent_id, code, seq, prep_location, created_by)
    values (r.id, 'jr', m_id, m_code || '-J' || lpad(j::text, 2, '0'), j, p_prep_location, auth.uid()) returning id into jr_id;
    insert into public.package_items (package_id, request_line_id, quantity) values (jr_id, l.id, (it ->> 'quantity')::int);
  end loop;
  if j = 0 then raise exception 'a package needs at least one line' using errcode = '22023'; end if;
  return app.finish_operation(p_op_id, jsonb_build_object('package_id', m_id, 'code', m_code, 'jr_cards', j));
end $$;

create or replace function public.package_void(p_op_id uuid, p_package_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; p public.packages;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'package_void'); if prev is not null then return prev; end if;
  select * into p from public.packages where id = p_package_id and kind = 'master';
  if not found then raise exception 'master package not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.requests where id = p.request_id and status not in ('reserved', 'in_preparation', 'ready')) then
    raise exception 'package of a shipped/closed request cannot be voided' using errcode = '22023';
  end if;
  update public.packages set voided = true where id = p.id or parent_id = p.id;
  perform app.add_history(p.request_id, (select status from public.requests where id = p.request_id),
    (select status from public.requests where id = p.request_id), 'Package ' || p.code || ' voided: ' || app.require_reason(p_reason), p_op_id, now());
  return app.finish_operation(p_op_id, jsonb_build_object('voided', p.code));
end $$;

-- QR lookup (handheld). The QR only carries an opaque token; the content is shown to signed-in staff.
create or replace function public.package_scan(p_qr_token text)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare p public.packages; r public.requests;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  select * into p from public.packages where qr_token = p_qr_token;
  if not found then raise exception 'unknown QR' using errcode = 'P0002'; end if;
  select * into r from public.requests where id = p.request_id;
  return jsonb_build_object(
    'package', jsonb_build_object('id', p.id, 'code', p.code, 'kind', p.kind, 'seq', p.seq, 'voided', p.voided,
       'verified_at', p.verified_at, 'prep_location', p.prep_location,
       'total_masters', (select count(*) from public.packages where request_id = r.id and kind = 'master' and not voided)),
    'request', jsonb_build_object('id', r.id, 'folio', r.folio, 'status', r.status, 'delivery_method', r.delivery_method),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('line_no', l.line_no, 'description', l.snap_description,
                     'quantity', pi.quantity, 'location', (select string_agg(distinct concat_ws(' · ', lo.furniture, lo.position), ', ')
                        from public.reservations rv join public.stock s on s.id = rv.stock_id left join public.locations lo on lo.id = s.location_id
                        where rv.request_line_id = l.id))
               order by l.line_no), '[]'::jsonb)
              from public.package_items pi join public.request_lines l on l.id = pi.request_line_id where pi.package_id = p.id));
end $$;

-- Verification scan: repeated scans are harmless (no inventory effect, first verification is kept)
create or replace function public.package_verify(p_op_id uuid, p_qr_token text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; p public.packages;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'package_verify'); if prev is not null then return prev; end if;
  update public.packages set verified_at = coalesce(verified_at, now()), verified_by = coalesce(verified_by, auth.uid())
   where qr_token = p_qr_token and not voided returning * into p;
  if not found then raise exception 'unknown or voided QR' using errcode = 'P0002'; end if;
  return app.finish_operation(p_op_id, jsonb_build_object('code', p.code, 'verified_at', p.verified_at));
end $$;

-- ------------------------------------------------------------------ shipments (USD)
create or replace function public.shipment_register(p_op_id uuid, p_request_id bigint, p_carrier text, p_tracking_no text,
  p_cost_usd numeric default null, p_label_created_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; r public.requests; sh public.shipments;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'shipment_register'); if prev is not null then return prev; end if;
  select * into r from public.requests where id = p_request_id;
  if r.delivery_method <> 'shipping' then raise exception 'pickup requests have no shipment' using errcode = '22023'; end if;
  if r.status in ('cancelled', 'delivered') then raise exception 'request is %', r.status using errcode = '22023'; end if;
  insert into public.shipments (request_id, carrier, tracking_no, cost_usd, label_created_at, created_by)
  values (r.id, upper(btrim(p_carrier)), upper(regexp_replace(p_tracking_no, '\s', '', 'g')), round(p_cost_usd, 2),
          coalesce(p_label_created_at, now()), auth.uid())
  returning * into sh;
  perform app.enqueue_notification('tracking_registered', r.id,
    jsonb_build_object('carrier', sh.carrier, 'tracking_no', sh.tracking_no), ':' || sh.tracking_no);
  return app.finish_operation(p_op_id, jsonb_build_object('shipment_id', sh.id,
    -- the same tracking number on other requests = consolidated shipment; shown to the user as a warning
    'shared_with', (select coalesce(jsonb_agg(q.folio), '[]'::jsonb) from public.shipments x join public.requests q on q.id = x.request_id
                     where x.carrier = sh.carrier and x.tracking_no = sh.tracking_no and x.id <> sh.id and x.status <> 'void')));
exception when unique_violation then
  raise exception 'DUPLICATE_TRACKING: % % is already registered (or its cost is already recorded on another request)', upper(btrim(p_carrier)), p_tracking_no using errcode = '23505';
end $$;

create or replace function public.shipment_set_cost(p_op_id uuid, p_shipment_id bigint, p_cost_usd numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'shipment_set_cost'); if prev is not null then return prev; end if;
  if p_cost_usd < 0 then raise exception 'cost must be >= 0' using errcode = '22023'; end if;
  if exists (select 1 from public.invoice_shipments where shipment_id = p_shipment_id) then
    raise exception 'cost already billed in an invoice; correct the invoice instead' using errcode = '22023';
  end if;
  perform app.require_reason(p_reason);
  begin
    update public.shipments set cost_usd = round(p_cost_usd, 2) where id = p_shipment_id;
  exception when unique_violation then
    raise exception 'COST_ALREADY_RECORDED: this tracking number already has its cost on another request' using errcode = '23505';
  end;
  return app.finish_operation(p_op_id, jsonb_build_object('shipment_id', p_shipment_id, 'cost_usd', round(p_cost_usd, 2)));
end $$;

-- ------------------------------------------------------------------ evidence (files live in the private bucket "evidence")
create or replace function public.evidence_register(p_op_id uuid, p_request_id bigint, p_kind app.evidence_kind, p_storage_path text,
  p_mime_type text, p_size_bytes integer, p_sha256 text, p_package_id bigint default null, p_incident_id bigint default null,
  p_event_at timestamptz default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; e public.evidences; folio text;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'evidence_register'); if prev is not null then return prev; end if;
  select r.folio into folio from public.requests r where r.id = p_request_id;
  if folio is null then raise exception 'request not found' using errcode = 'P0002'; end if;
  if p_storage_path not like folio || '/%' then
    raise exception 'evidence path must start with the folio (%/…)', folio using errcode = '22023';
  end if;
  insert into public.evidences (request_id, package_id, incident_id, kind, storage_path, mime_type, size_bytes, sha256,
                                uploaded_by, event_at, notes)
  values (p_request_id, p_package_id, p_incident_id, p_kind, p_storage_path, p_mime_type, p_size_bytes, lower(p_sha256),
          auth.uid(), p_event_at, p_notes)
  on conflict (request_id, sha256) where not voided do nothing
  returning * into e;
  if e.id is null then
    return app.finish_operation(p_op_id, jsonb_build_object('status', 'duplicate', 'message', 'The same file is already attached to this request'));
  end if;
  return app.finish_operation(p_op_id, jsonb_build_object('status', 'created', 'evidence_id', e.id));
end $$;

create or replace function public.evidence_void(p_op_id uuid, p_evidence_id bigint, p_reason text, p_replaced_by bigint default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb;
begin
  perform app.require_role('admin', 'cesantoni');
  prev := app.begin_operation(p_op_id, 'evidence_void'); if prev is not null then return prev; end if;
  update public.evidences set voided = true, void_reason = app.require_reason(p_reason), voided_by = auth.uid(), voided_at = now(),
         replaced_by = p_replaced_by
   where id = p_evidence_id and not voided;
  if not found then raise exception 'evidence not found or already voided' using errcode = 'P0002'; end if;
  return app.finish_operation(p_op_id, jsonb_build_object('voided', p_evidence_id));
end $$;

-- ------------------------------------------------------------------ incidents
create or replace function public.incident_open(p_op_id uuid, p_request_id bigint, p_description text, p_package_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; i public.incidents;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'incident_open'); if prev is not null then return prev; end if;
  insert into public.incidents (request_id, package_id, description, opened_by, owner_org)
  values (p_request_id, p_package_id, btrim(p_description), auth.uid(), (select org_id from public.profiles where user_id = auth.uid()))
  returning * into i;
  perform app.enqueue_notification('incident', p_request_id, jsonb_build_object('incident_id', i.id, 'description', i.description), ':inc:' || i.id);
  return app.finish_operation(p_op_id, jsonb_build_object('incident_id', i.id));
end $$;

create or replace function public.incident_resolve(p_op_id uuid, p_incident_id bigint, p_resolution text, p_cancel boolean default false)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb;
begin
  perform app.require_role('admin', 'cesantoni', 'armex');
  prev := app.begin_operation(p_op_id, 'incident_resolve'); if prev is not null then return prev; end if;
  update public.incidents set status = case when p_cancel then 'cancelled'::app.incident_status else 'resolved' end,
         resolution = app.require_reason(p_resolution), resolved_by = auth.uid(), resolved_at = now()
   where id = p_incident_id and status in ('open', 'in_progress');
  if not found then raise exception 'incident not found or already closed' using errcode = 'P0002'; end if;
  return app.finish_operation(p_op_id, jsonb_build_object('incident_id', p_incident_id));
end $$;

-- ------------------------------------------------------------------ invoices (registration only — no electronic tax stamping)
create or replace function public.invoice_register(p_op_id uuid, p_invoice jsonb, p_request_ids bigint[] default '{}',
  p_shipments jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; inv public.invoices; s jsonb; warn jsonb := '[]'::jsonb; rid bigint;
begin
  perform app.require_role('admin', 'billing');
  prev := app.begin_operation(p_op_id, 'invoice_register'); if prev is not null then return prev; end if;
  -- possible duplicates with a different number (same issuer, total and date)
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.number)), '[]'::jsonb) into warn
    from public.invoices i
   where upper(i.issuer) = upper(btrim(p_invoice ->> 'issuer')) and i.total = (p_invoice ->> 'total')::numeric
     and i.issue_date = (p_invoice ->> 'issue_date')::date and i.status <> 'void';
  begin
    insert into public.invoices (issuer, receiver, number, issue_date, concept, currency, subtotal, tax, total, notes, created_by)
    values (btrim(p_invoice ->> 'issuer'), btrim(p_invoice ->> 'receiver'), btrim(p_invoice ->> 'number'),
            (p_invoice ->> 'issue_date')::date, btrim(p_invoice ->> 'concept'), upper(p_invoice ->> 'currency'),
            round((p_invoice ->> 'subtotal')::numeric, 2), round(coalesce((p_invoice ->> 'tax')::numeric, 0), 2),
            round((p_invoice ->> 'total')::numeric, 2), p_invoice ->> 'notes', auth.uid())
    returning * into inv;
  exception when unique_violation then
    raise exception 'DUPLICATE_INVOICE: issuer % already has invoice number %', p_invoice ->> 'issuer', p_invoice ->> 'number' using errcode = '23505';
  end;
  foreach rid in array coalesce(p_request_ids, '{}') loop
    insert into public.invoice_requests values (inv.id, rid);
  end loop;
  for s in select * from jsonb_array_elements(p_shipments) loop
    if inv.currency <> 'USD' then raise exception 'shipping costs are USD; the invoice is %', inv.currency using errcode = '22023'; end if;
    begin
      insert into public.invoice_shipments values (inv.id, (s ->> 'shipment_id')::bigint, round((s ->> 'amount_usd')::numeric, 2));
    exception when unique_violation then
      raise exception 'COST_ALREADY_BILLED: shipment % is already in another invoice', s ->> 'shipment_id' using errcode = '23505';
    end;
  end loop;
  return app.finish_operation(p_op_id, jsonb_build_object('invoice_id', inv.id, 'possible_duplicates', warn));
end $$;

create or replace function public.invoice_document_register(p_op_id uuid, p_invoice_id bigint, p_storage_path text, p_doc_type text,
  p_mime_type text, p_size_bytes integer, p_sha256 text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; d_id bigint;
begin
  perform app.require_role('admin', 'billing');
  prev := app.begin_operation(p_op_id, 'invoice_document_register'); if prev is not null then return prev; end if;
  insert into public.invoice_documents (invoice_id, storage_path, doc_type, mime_type, size_bytes, sha256, uploaded_by)
  values (p_invoice_id, p_storage_path, p_doc_type, p_mime_type, p_size_bytes, lower(p_sha256), auth.uid()) returning id into d_id;
  perform app.enqueue_notification('invoice_document', r.request_id, jsonb_build_object('invoice_id', p_invoice_id), ':doc:' || d_id)
     from public.invoice_requests r where r.invoice_id = p_invoice_id;
  return app.finish_operation(p_op_id, jsonb_build_object('document_id', d_id));
end $$;

create or replace function public.invoice_set_status(p_op_id uuid, p_invoice_id bigint, p_status app.invoice_status, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb;
begin
  perform app.require_role('admin', 'billing');
  prev := app.begin_operation(p_op_id, 'invoice_set_status'); if prev is not null then return prev; end if;
  update public.invoices set status = p_status, updated_by = auth.uid(),
         notes = concat_ws(E'\n', notes, now()::date || ' ' || p_status || ': ' || app.require_reason(p_reason))
   where id = p_invoice_id;
  if not found then raise exception 'invoice not found' using errcode = 'P0002'; end if;
  return app.finish_operation(p_op_id, jsonb_build_object('invoice_id', p_invoice_id, 'status', p_status));
end $$;

-- ------------------------------------------------------------------ users (accounts are created with Supabase Auth invitations)
create or replace function public.user_set_profile(p_user_id uuid, p_email text, p_full_name text, p_org_code text,
  p_role app.user_role, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare org smallint;
begin
  perform app.require_role('admin', 'service');
  select id into org from public.organizations where code = upper(p_org_code);
  if org is null then raise exception 'unknown organization %', p_org_code using errcode = 'P0002'; end if;
  insert into public.profiles (user_id, email, full_name, org_id, role, active)
  values (p_user_id, lower(btrim(p_email)), btrim(p_full_name), org, p_role, p_active)
  on conflict (user_id) do update set full_name = excluded.full_name, org_id = excluded.org_id,
     role = excluded.role, active = excluded.active;
  return jsonb_build_object('user_id', p_user_id, 'role', p_role, 'active', p_active);
end $$;

grant execute on function public.package_create(uuid, bigint, jsonb, text), public.package_void(uuid, bigint, text),
  public.package_scan(text), public.package_verify(uuid, text),
  public.shipment_register(uuid, bigint, text, text, numeric, timestamptz), public.shipment_set_cost(uuid, bigint, numeric, text),
  public.evidence_register(uuid, bigint, app.evidence_kind, text, text, integer, text, bigint, bigint, timestamptz, text),
  public.evidence_void(uuid, bigint, text, bigint), public.incident_open(uuid, bigint, text, bigint),
  public.incident_resolve(uuid, bigint, text, boolean), public.invoice_register(uuid, jsonb, bigint[], jsonb),
  public.invoice_document_register(uuid, bigint, text, text, text, integer, text),
  public.invoice_set_status(uuid, bigint, app.invoice_status, text),
  public.user_set_profile(uuid, text, text, text, app.user_role, boolean)
to authenticated;
