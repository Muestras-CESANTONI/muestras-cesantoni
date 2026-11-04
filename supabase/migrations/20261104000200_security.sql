-- =====================================================================================
-- Security: server-side roles, RLS, audit trail, append-only logs.
-- Writes never happen through direct table access from the browser: authenticated/anon
-- only get SELECT (filtered by RLS); every change goes through SECURITY DEFINER functions
-- that check the caller's active profile in the database.
-- =====================================================================================

-- ------------------------------------------------------------------ caller identity
create or replace function app.caller_role() returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when auth.role() = 'service_role' then 'service'
    else (select p.role::text from public.profiles p where p.user_id = auth.uid() and p.active)
  end
$$;

create or replace function app.caller_label() returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when auth.role() = 'service_role' then coalesce(nullif(current_setting('app.actor_label', true), ''), 'system')
    else coalesce((select p.email from public.profiles p where p.user_id = auth.uid()), 'anonymous')
  end
$$;

-- Raises 42501 unless the caller has one of the given roles ('service' = trusted server code).
create or replace function app.require_role(variadic allowed text[]) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare r text := app.caller_role();
begin
  if r is null or not (r = any(allowed)) then
    raise exception 'permission denied: role % cannot perform this action', coalesce(r, 'none')
      using errcode = '42501';
  end if;
  return r;
end $$;

create or replace function app.is_internal() returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.caller_role() in ('admin', 'cesantoni', 'armex', 'billing', 'service'), false)
$$;
create or replace function app.has_role(variadic allowed text[]) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.caller_role() = any(allowed), false)
$$;

-- ------------------------------------------------------------------ idempotent operations
-- Returns the stored result when the op_id was already processed (double click / retry),
-- otherwise registers it and returns NULL so the caller proceeds. The row lock taken by the
-- INSERT serialises concurrent retries of the same op_id.
create or replace function app.begin_operation(p_op_id uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare prev public.operations;
begin
  if p_op_id is null then
    raise exception 'operation id is required' using errcode = '22023';
  end if;
  insert into public.operations (op_id, kind, actor, actor_label)
  values (p_op_id, p_kind, auth.uid(), app.caller_label())
  on conflict (op_id) do nothing;
  if found then return null; end if;
  select * into prev from public.operations where op_id = p_op_id;
  if prev.kind <> p_kind then
    raise exception 'operation id % was already used for %', p_op_id, prev.kind using errcode = '23505';
  end if;
  return coalesce(prev.result, '{}'::jsonb) || jsonb_build_object('replayed', true);
end $$;

create or replace function app.finish_operation(p_op_id uuid, p_result jsonb) returns jsonb
language sql security definer set search_path = public, app as $$
  update public.operations set result = p_result where op_id = p_op_id;
  select p_result || jsonb_build_object('replayed', false);
$$;

-- ------------------------------------------------------------------ append-only tables
create or replace function app.forbid_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only: % is not allowed (register a correcting entry instead)', tg_table_name, tg_op
    using errcode = '42501';
end $$;

create trigger inventory_movements_append_only before update or delete on public.inventory_movements
  for each row execute function app.forbid_change();
create trigger request_status_history_append_only before update or delete on public.request_status_history
  for each row execute function app.forbid_change();
create trigger audit_log_append_only before update or delete on public.audit_log
  for each row execute function app.forbid_change();
create trigger evidences_no_delete before delete on public.evidences
  for each row execute function app.forbid_change();
create trigger invoice_documents_no_delete before delete on public.invoice_documents
  for each row execute function app.forbid_change();
create trigger requests_no_delete before delete on public.requests
  for each row execute function app.forbid_change();
create trigger reservations_no_delete before delete on public.reservations
  for each row execute function app.forbid_change();

-- request lines keep their historical snapshot
create or replace function app.request_line_immutable_snapshot() returns trigger language plpgsql as $$
begin
  if (new.snap_model, new.snap_color, new.snap_finish, new.snap_sample_size, new.snap_sample_type, new.snap_description)
     is distinct from
     (old.snap_model, old.snap_color, old.snap_finish, old.snap_sample_size, old.snap_sample_type, old.snap_description) then
    raise exception 'request line snapshot is historical and cannot be modified' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger request_lines_snapshot before update on public.request_lines
  for each row execute function app.request_line_immutable_snapshot();

-- ------------------------------------------------------------------ at least one active admin
create or replace function app.keep_one_admin() returns trigger language plpgsql as $$
begin
  if (tg_op = 'UPDATE' and old.role = 'admin' and old.active and not (new.role = 'admin' and new.active))
     or (tg_op = 'DELETE' and old.role = 'admin' and old.active) then
    if not exists (select 1 from public.profiles where role = 'admin' and active and user_id <> old.user_id) then
      raise exception 'at least one active administrator must remain' using errcode = '23514';
    end if;
  end if;
  return coalesce(new, old);
end $$;
create trigger profiles_keep_one_admin before update or delete on public.profiles
  for each row execute function app.keep_one_admin();

-- ------------------------------------------------------------------ generic audit
create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare rid text;
begin
  rid := coalesce(to_jsonb(new) ->> 'id', to_jsonb(old) ->> 'id', to_jsonb(new) ->> 'user_id', to_jsonb(old) ->> 'user_id',
                  to_jsonb(new) ->> 'key', to_jsonb(old) ->> 'key', to_jsonb(new) ->> 'code', to_jsonb(old) ->> 'code', '?');
  insert into public.audit_log (table_name, record_id, action, old_values, new_values, actor, actor_label)
  values (tg_table_name, rid, tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          auth.uid(), app.caller_label());
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['profiles', 'products', 'variants', 'variant_images', 'sample_skus', 'finishes', 'locations',
                           'stock', 'requests', 'request_lines', 'reservations', 'packages', 'package_items', 'shipments',
                           'incidents', 'evidences', 'invoices', 'invoice_requests', 'invoice_shipments',
                           'invoice_documents', 'notification_recipients', 'settings', 'imports', 'legacy_references']
  loop
    execute format('create trigger %I after insert or update or delete on public.%I for each row execute function app.audit()',
                   t || '_audit', t);
  end loop;
end $$;

-- ------------------------------------------------------------------ updated_at
create or replace function app.touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
do $$
declare t text;
begin
  foreach t in array array['profiles', 'products', 'variants', 'sample_skus', 'stock', 'requests', 'shipments', 'invoices']
  loop
    execute format('create trigger %I before update on public.%I for each row execute function app.touch()', t || '_touch', t);
  end loop;
end $$;

-- ------------------------------------------------------------------ privileges
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;
revoke all on schema app from public, anon, authenticated;
grant usage on schema app to authenticated, service_role;   -- needed for enum types in results
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all tables in schema app to service_role;
grant execute on all functions in schema app to service_role;
-- helper functions are callable inside policies by authenticated users
grant execute on function app.caller_role(), app.is_internal(), app.has_role(text[]) to authenticated, anon;

-- read access (RLS filters rows)
grant select on public.organizations, public.profiles, public.finishes, public.products, public.variants,
  public.variant_images, public.sample_skus, public.warehouses, public.locations, public.stock,
  public.inventory_movements, public.imports, public.import_rows, public.legacy_references, public.legacy_movements,
  public.requests, public.request_lines, public.reservations, public.request_status_history,
  public.packages, public.package_items, public.shipments, public.incidents, public.evidences,
  public.invoices, public.invoice_requests, public.invoice_shipments, public.invoice_documents,
  public.notification_recipients, public.notifications, public.audit_log, public.settings,
  public.operations, public.stock_overview
to authenticated;

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- internal staff (admin, CESANTONI, ARMEX) see catalog, warehouse and operations
create policy staff_read on public.organizations for select to authenticated using (app.is_internal());
create policy self_or_admin_read on public.profiles for select to authenticated
  using (user_id = auth.uid() or app.has_role('admin'));
do $$
declare t text;
begin
  foreach t in array array['finishes', 'products', 'variants', 'variant_images', 'sample_skus', 'warehouses', 'locations',
                           'stock', 'inventory_movements', 'imports', 'import_rows', 'legacy_references', 'legacy_movements',
                           'packages', 'package_items', 'incidents', 'evidences', 'reservations', 'operations']
  loop
    execute format($p$create policy ops_read on public.%I for select to authenticated
                      using (app.has_role('admin', 'cesantoni', 'armex'))$p$, t);
  end loop;
end $$;

-- requests: staff (incl. billing) see all; a client sees only requests linked to their account
create policy staff_read on public.requests for select to authenticated using (app.is_internal());
create policy client_own on public.requests for select to authenticated
  using (app.has_role('client') and customer_user_id = auth.uid());
create policy staff_read on public.request_lines for select to authenticated using (app.is_internal());
create policy client_own on public.request_lines for select to authenticated
  using (app.has_role('client') and exists (select 1 from public.requests r where r.id = request_id and r.customer_user_id = auth.uid()));
create policy staff_read on public.request_status_history for select to authenticated using (app.is_internal());
create policy client_own on public.request_status_history for select to authenticated
  using (app.has_role('client') and exists (select 1 from public.requests r where r.id = request_id and r.customer_user_id = auth.uid()));
create policy staff_read on public.shipments for select to authenticated using (app.is_internal());

-- billing data: admin, CESANTONI, billing
do $$
declare t text;
begin
  foreach t in array array['invoices', 'invoice_requests', 'invoice_shipments', 'invoice_documents'] loop
    execute format($p$create policy billing_read on public.%I for select to authenticated
                      using (app.has_role('admin', 'cesantoni', 'billing'))$p$, t);
  end loop;
end $$;

create policy admin_read on public.notification_recipients for select to authenticated using (app.has_role('admin', 'cesantoni'));
create policy admin_read on public.notifications for select to authenticated using (app.has_role('admin', 'cesantoni'));
create policy admin_read on public.audit_log for select to authenticated using (app.has_role('admin'));
create policy staff_read on public.settings for select to authenticated using (app.is_internal());

-- default privileges: future tables are not exposed by accident
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
