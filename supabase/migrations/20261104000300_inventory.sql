-- =====================================================================================
-- Inventory engine. Every change of on_hand / reserved goes through app.stock_change(),
-- which locks the stock row, validates and writes exactly one movement with before/after.
--   Available = on_hand - reserved
-- =====================================================================================

create or replace function app.stock_change(
  p_stock_id    bigint,
  p_movement    app.movement_type,
  p_d_on_hand   integer,
  p_d_reserved  integer,
  p_op_id       uuid,
  p_reason      text,
  p_request_id  bigint default null,
  p_occurred_at timestamptz default null,
  p_import_id   bigint default null
) returns public.inventory_movements
language plpgsql security definer set search_path = public, app as $$
declare
  s   public.stock;
  mv  public.inventory_movements;
  qty integer;
begin
  select * into s from public.stock where id = p_stock_id for update;
  if not found then raise exception 'stock row % not found', p_stock_id using errcode = 'P0002'; end if;

  if s.on_hand + p_d_on_hand < 0 then
    raise exception 'INSUFFICIENT_STOCK: % would leave negative stock (on hand %, change %)', p_stock_id, s.on_hand, p_d_on_hand
      using errcode = '23514';
  end if;
  if s.reserved + p_d_reserved < 0 then
    raise exception 'INVALID_RESERVATION: % would leave negative reservation', p_stock_id using errcode = '23514';
  end if;
  if s.reserved + p_d_reserved > s.on_hand + p_d_on_hand then
    raise exception 'INSUFFICIENT_AVAILABLE: stock % has % available, % requested',
      p_stock_id, s.on_hand - s.reserved, p_d_reserved - p_d_on_hand using errcode = '23514';
  end if;

  qty := case when p_d_on_hand <> 0 then p_d_on_hand else p_d_reserved end;

  update public.stock
     set on_hand = s.on_hand + p_d_on_hand,
         reserved = s.reserved + p_d_reserved,
         version = s.version + 1
   where id = s.id;

  insert into public.inventory_movements (op_id, stock_id, sku_id, location_id, movement, quantity,
      on_hand_before, on_hand_after, reserved_before, reserved_after, request_id, reason, actor, actor_label,
      occurred_at, import_id)
  values (p_op_id, s.id, s.sku_id, s.location_id, p_movement, qty,
      s.on_hand, s.on_hand + p_d_on_hand, s.reserved, s.reserved + p_d_reserved, p_request_id, p_reason,
      auth.uid(), app.caller_label(), coalesce(p_occurred_at, now()), p_import_id)
  returning * into mv;
  return mv;
end $$;

create or replace function app.require_reason(p_reason text) returns text language plpgsql immutable as $$
begin
  if p_reason is null or length(btrim(p_reason)) < 3 then
    raise exception 'a reason is required (min. 3 characters)' using errcode = '22023';
  end if;
  return btrim(p_reason);
end $$;

-- ------------------------------------------------------------------ locations
create or replace function public.location_upsert(p_warehouse text, p_furniture text, p_position text, p_notes text default null)
returns bigint language plpgsql security definer set search_path = public, app as $$
declare wid smallint; lid bigint;
begin
  perform app.require_role('admin', 'cesantoni', 'service');
  select id into wid from public.warehouses where code = upper(p_warehouse);
  if wid is null then raise exception 'unknown warehouse %', p_warehouse using errcode = 'P0002'; end if;
  if coalesce(btrim(p_furniture), '') = '' or coalesce(btrim(p_position), '') = '' then
    raise exception 'furniture and position are required' using errcode = '22023';
  end if;
  insert into public.locations (warehouse_id, furniture, position, notes)
  values (wid, upper(btrim(p_furniture)), btrim(p_position), p_notes)
  on conflict (warehouse_id, furniture, position) do update set notes = coalesce(excluded.notes, locations.notes)
  returning id into lid;
  return lid;
end $$;

-- ------------------------------------------------------------------ goods receipt (entrada)
create or replace function public.inv_receive(p_op_id uuid, p_sku_code text, p_location_id bigint, p_quantity integer,
  p_reason text, p_occurred_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; sku public.sample_skus; sid bigint; mv public.inventory_movements;
begin
  perform app.require_role('admin', 'cesantoni');
  prev := app.begin_operation(p_op_id, 'inv_receive'); if prev is not null then return prev; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception 'quantity must be positive' using errcode = '22023'; end if;
  select * into sku from public.sample_skus where code = upper(btrim(p_sku_code));
  if not found then raise exception 'unknown SKU %', p_sku_code using errcode = 'P0002'; end if;
  insert into public.stock (sku_id, location_id) values (sku.id, p_location_id)
  on conflict (sku_id, coalesce(location_id, 0)) do nothing;
  select id into sid from public.stock where sku_id = sku.id and coalesce(location_id, 0) = coalesce(p_location_id, 0);
  mv := app.stock_change(sid, 'receipt', p_quantity, 0, p_op_id, app.require_reason(p_reason), null, p_occurred_at);
  return app.finish_operation(p_op_id, jsonb_build_object('stock_id', sid, 'movement_id', mv.id, 'on_hand', mv.on_hand_after));
end $$;

-- ------------------------------------------------------------------ justified adjustment (+/-)
create or replace function public.inv_adjust(p_op_id uuid, p_stock_id bigint, p_delta integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; mv public.inventory_movements;
begin
  perform app.require_role('admin', 'cesantoni');   -- ARMEX never adjusts freely
  prev := app.begin_operation(p_op_id, 'inv_adjust'); if prev is not null then return prev; end if;
  if p_delta is null or p_delta = 0 then raise exception 'delta must be non-zero' using errcode = '22023'; end if;
  mv := app.stock_change(p_stock_id, 'adjust', p_delta, 0, p_op_id, app.require_reason(p_reason));
  return app.finish_operation(p_op_id, jsonb_build_object('movement_id', mv.id, 'on_hand', mv.on_hand_after));
end $$;

-- ------------------------------------------------------------------ absolute physical count
-- A count lower than the active reservations is NOT applied: it returns status 'review'.
create or replace function public.inv_count(p_op_id uuid, p_stock_id bigint, p_counted integer, p_reason text,
  p_expected_version bigint default null, p_counted_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; s public.stock; mv public.inventory_movements;
begin
  perform app.require_role('admin', 'cesantoni');
  prev := app.begin_operation(p_op_id, 'inv_count'); if prev is not null then return prev; end if;
  if p_counted is null or p_counted < 0 then raise exception 'counted quantity must be >= 0' using errcode = '22023'; end if;
  select * into s from public.stock where id = p_stock_id for update;
  if not found then raise exception 'stock row % not found', p_stock_id using errcode = 'P0002'; end if;
  if p_expected_version is not null and s.version <> p_expected_version then
    return app.finish_operation(p_op_id, jsonb_build_object('status', 'stale', 'current_version', s.version,
      'on_hand', s.on_hand, 'reserved', s.reserved));
  end if;
  if p_counted < s.reserved then
    return app.finish_operation(p_op_id, jsonb_build_object('status', 'review', 'counted', p_counted,
      'reserved', s.reserved, 'message', 'Count is lower than active reservations: review the affected requests first.'));
  end if;
  if p_counted <> s.on_hand then
    mv := app.stock_change(p_stock_id, 'count_adjust', p_counted - s.on_hand, 0, p_op_id, app.require_reason(p_reason), null, p_counted_at);
  end if;
  update public.stock set validation_status = 'validated', last_counted_at = coalesce(p_counted_at, now()) where id = p_stock_id;
  return app.finish_operation(p_op_id, jsonb_build_object('status', 'applied', 'movement_id', mv.id,
    'on_hand', p_counted, 'difference', p_counted - s.on_hand));
end $$;

-- ------------------------------------------------------------------ relocation (only available pieces move)
create or replace function public.inv_relocate(p_op_id uuid, p_stock_id bigint, p_to_location_id bigint, p_quantity integer, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; src public.stock; dst_id bigint;
begin
  perform app.require_role('admin', 'cesantoni');
  prev := app.begin_operation(p_op_id, 'inv_relocate'); if prev is not null then return prev; end if;
  select * into src from public.stock where id = p_stock_id;
  if not found then raise exception 'stock row % not found', p_stock_id using errcode = 'P0002'; end if;
  if p_to_location_id is not distinct from src.location_id then raise exception 'origin and destination are the same' using errcode = '22023'; end if;
  insert into public.stock (sku_id, location_id, validation_status) values (src.sku_id, p_to_location_id, src.validation_status)
  on conflict (sku_id, coalesce(location_id, 0)) do nothing;
  select id into dst_id from public.stock where sku_id = src.sku_id and coalesce(location_id, 0) = coalesce(p_to_location_id, 0);
  -- lock in id order to avoid deadlocks
  perform 1 from public.stock where id in (src.id, dst_id) order by id for update;
  perform app.stock_change(src.id, 'relocate_out', -p_quantity, 0, p_op_id, app.require_reason(p_reason));
  perform app.stock_change(dst_id, 'relocate_in', p_quantity, 0, p_op_id, app.require_reason(p_reason));
  return app.finish_operation(p_op_id, jsonb_build_object('from_stock_id', src.id, 'to_stock_id', dst_id, 'quantity', p_quantity));
end $$;

-- ------------------------------------------------------------------ bulk count / receipt from a spreadsheet
-- Step 1: preview. rows = [{"row_no":2,"sku_code":"HOUSTON2-001","furniture":"A","position":"1","quantity":88}, …]
create or replace function public.import_preview(p_kind app.import_kind, p_file_name text, p_file_sha256 text, p_rows jsonb, p_warehouse text default 'HOUSTON')
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  imp_id bigint; r jsonb; sku public.sample_skus; s public.stock; loc_id bigint; q integer; st text; msg text;
  seen text[] := '{}'; key text; n_valid int := 0; n_rej int := 0; n_rev int := 0; prop int; stock_ids bigint[] := '{}';
begin
  perform app.require_role('admin', 'cesantoni');
  if p_kind = 'initial_migration' then raise exception 'initial migration is loaded by the migration script' using errcode = '22023'; end if;
  if exists (select 1 from public.imports where file_sha256 = p_file_sha256 and kind = p_kind and status = 'applied') then
    raise exception 'DUPLICATE_FILE: this file was already applied as %', p_kind using errcode = '23505';
  end if;
  insert into public.imports (kind, file_name, file_sha256, created_by, created_by_label)
  values (p_kind, p_file_name, lower(p_file_sha256), auth.uid(), app.caller_label()) returning id into imp_id;

  for r in select * from jsonb_array_elements(p_rows) loop
    st := 'valid'; msg := null; s := null; loc_id := null; sku := null; prop := null;
    begin
      q := (r ->> 'quantity')::integer;
    exception when others then q := null; end;
    select * into sku from public.sample_skus where code = upper(btrim(r ->> 'sku_code'));
    if sku.id is null then st := 'rejected'; msg := 'Unknown SKU';
    elsif q is null or q < 0 or (r ->> 'quantity') !~ '^\s*[0-9]+\s*$' then st := 'rejected'; msg := 'Quantity must be a whole number >= 0';
    elsif p_kind = 'receipt' and q = 0 then st := 'rejected'; msg := 'A receipt must be > 0';
    else
      select l.id into loc_id from public.locations l join public.warehouses w on w.id = l.warehouse_id
       where w.code = upper(p_warehouse) and l.furniture = upper(btrim(r ->> 'furniture')) and l.position = btrim(r ->> 'position');
      if coalesce(r ->> 'furniture', '') <> '' and loc_id is null then st := 'rejected'; msg := 'Unknown location';
      else
        key := sku.code || '@' || coalesce(loc_id::text, '-');
        if key = any(seen) then st := 'rejected'; msg := 'Duplicated SKU/location in file';
        else
          seen := seen || key;
          select * into s from public.stock where sku_id = sku.id and coalesce(location_id, 0) = coalesce(loc_id, 0);
          if p_kind = 'count_absolute' then
            if s.id is null and loc_id is null then st := 'rejected'; msg := 'SKU has no stock row without location; specify the location';
            else
              prop := q;
              if q < coalesce(s.reserved, 0) then st := 'review'; msg := 'Count lower than active reservations'; end if;
            end if;
          else
            prop := coalesce(s.on_hand, 0) + q;
          end if;
        end if;
      end if;
    end if;
    if s.id is not null then stock_ids := stock_ids || s.id; end if;
    insert into public.import_rows (import_id, row_no, raw, sku_code, location_label, stock_id, current_on_hand, current_reserved,
                                    proposed, difference, status, message)
    values (imp_id, coalesce((r ->> 'row_no')::int, 0), r, upper(btrim(r ->> 'sku_code')),
            nullif(concat_ws(' · ', r ->> 'furniture', r ->> 'position'), ''), s.id, s.on_hand, s.reserved,
            prop, prop - coalesce(s.on_hand, 0), st, msg);
    if st = 'valid' then n_valid := n_valid + 1; elsif st = 'review' then n_rev := n_rev + 1; else n_rej := n_rej + 1; end if;
  end loop;

  update public.imports set rows_total = n_valid + n_rej + n_rev, rows_valid = n_valid, rows_rejected = n_rej,
         snapshot_hash = app.stock_snapshot_hash(imp_id),
         summary = jsonb_build_object('review', n_rev)
   where id = imp_id;
  return jsonb_build_object('import_id', imp_id, 'valid', n_valid, 'rejected', n_rej, 'review', n_rev);
end $$;

-- hash of (stock id, version) of every row touched by the import: detects changes after the preview
create or replace function app.stock_snapshot_hash(p_import_id bigint) returns text
language sql stable security definer set search_path = public, app as $$
  select md5(coalesce(string_agg(s.id::text || ':' || s.version::text, ',' order by s.id), ''))
    from public.stock s
   where s.id in (select stock_id from public.import_rows where import_id = p_import_id and stock_id is not null)
$$;

-- Step 2: apply in a single transaction. Refuses if anything changed since the preview,
-- if there are rows under review, or if the same file was already applied.
create or replace function public.import_apply(p_op_id uuid, p_import_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare prev jsonb; imp public.imports; r public.import_rows; sid bigint; sku_id bigint; loc bigint; n int := 0; v_reason text;
begin
  perform app.require_role('admin', 'cesantoni');
  v_reason := app.require_reason(p_reason);
  prev := app.begin_operation(p_op_id, 'import_apply'); if prev is not null then return prev; end if;
  select * into imp from public.imports where id = p_import_id for update;
  if not found then raise exception 'import % not found', p_import_id using errcode = 'P0002'; end if;
  if imp.status <> 'preview' then raise exception 'import % is %, not preview', p_import_id, imp.status using errcode = '22023'; end if;
  if (imp.summary ->> 'review')::int > 0 then
    raise exception 'IMPORT_NEEDS_REVIEW: % rows are below active reservations', imp.summary ->> 'review' using errcode = '23514';
  end if;
  -- lock every affected stock row, then compare against the preview snapshot
  perform 1 from public.stock where id in (select stock_id from public.import_rows where import_id = imp.id) order by id for update;
  if app.stock_snapshot_hash(imp.id) is distinct from imp.snapshot_hash then
    update public.imports set status = 'stale' where id = imp.id;
    return app.finish_operation(p_op_id, jsonb_build_object('status', 'stale',
      'message', 'Inventory changed after the preview. Generate a new preview and review the differences.'));
  end if;

  for r in select * from public.import_rows where import_id = imp.id and status = 'valid' order by row_no loop
    sid := r.stock_id;
    if sid is null then   -- receipt into a location that had no stock row yet
      select k.id into sku_id from public.sample_skus k where k.code = r.sku_code;
      select l.id into loc from public.locations l join public.warehouses w on w.id = l.warehouse_id
       where w.code = 'HOUSTON' and l.furniture = upper(btrim(r.raw ->> 'furniture')) and l.position = btrim(r.raw ->> 'position');
      insert into public.stock (sku_id, location_id) values (sku_id, loc) returning id into sid;
    end if;
    if imp.kind = 'count_absolute' then
      if r.difference <> 0 then
        perform app.stock_change(sid, 'count_adjust', r.difference, 0, p_op_id, v_reason, null, null, imp.id);
      end if;
      update public.stock set validation_status = 'validated', last_counted_at = now() where id = sid;
    else
      perform app.stock_change(sid, 'receipt', (r.raw ->> 'quantity')::int, 0, p_op_id, v_reason, null, null, imp.id);
    end if;
    n := n + 1;
  end loop;

  update public.imports set status = 'applied', reason = v_reason, applied_by = auth.uid(), applied_at = now(), apply_op_id = p_op_id
   where id = imp.id;
  return app.finish_operation(p_op_id, jsonb_build_object('status', 'applied', 'rows_applied', n));
end $$;

grant execute on function public.location_upsert(text, text, text, text), public.inv_receive(uuid, text, bigint, integer, text, timestamptz),
  public.inv_adjust(uuid, bigint, integer, text), public.inv_count(uuid, bigint, integer, text, bigint, timestamptz),
  public.inv_relocate(uuid, bigint, bigint, integer, text), public.import_preview(app.import_kind, text, text, jsonb, text),
  public.import_apply(uuid, bigint, text)
to authenticated;
