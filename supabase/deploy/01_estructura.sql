-- CESANTONI Samples · estructura completa. Pegar TODO en Supabase › SQL Editor › Run (una sola vez).

-- ===================================================== 20261104000100_core_schema.sql
-- =====================================================================================
-- CESANTONI · ARMEX Samples Platform — core schema (v1)
-- Single source of truth for catalog, inventory, requests, operations and billing.
-- Rules enforced by the database (not only by the UI):
--   * no negative stock or reservations, reserved <= on_hand  (available = on_hand - reserved)
--   * movements and status history are append-only
--   * request lines keep a historical snapshot (renaming a product never rewrites old requests)
--   * every mutating operation carries an operation id (idempotency against double click / retries)
-- =====================================================================================
create schema if not exists extensions;          -- Supabase keeps extensions here
create extension if not exists pgcrypto with schema extensions;

create schema if not exists app;      -- internal helpers, never exposed through the API
comment on schema app is 'Internal helpers (not exposed by PostgREST).';

-- ------------------------------------------------------------------ enumerations
create type app.user_role        as enum ('admin', 'cesantoni', 'armex', 'billing', 'client');
create type app.product_category as enum ('tile', 'paver', 'other');
create type app.record_status    as enum ('active', 'inactive');
create type app.sample_type      as enum ('cut_sample', 'full_piece');
create type app.stock_validation as enum ('pending_physical_validation', 'validated');
create type app.movement_type    as enum (
  'initial_load',      -- balance imported from a legacy file (pending physical validation)
  'receipt',           -- goods received (adds on_hand)
  'count_adjust',      -- absolute physical count (sets on_hand)
  'adjust',            -- justified manual correction (+/-)
  'reserve',           -- reservation created (reserved +)
  'release',           -- reservation released by cancellation / edit (reserved -)
  'ship',              -- physical exit: on_hand - and reserved - (consumes the reservation)
  'return_receipt',    -- confirmed return in sellable condition (on_hand +)
  'relocate_out', 'relocate_in');
create type app.delivery_method  as enum ('shipping', 'pickup');
create type app.request_status   as enum (
  'submitted', 'reserved', 'in_preparation', 'ready', 'shipped',
  'ready_for_pickup', 'collected', 'delivered', 'on_hold', 'cancelled');
create type app.reservation_status as enum ('active', 'consumed', 'released');
create type app.import_kind      as enum ('initial_migration', 'count_absolute', 'receipt');
create type app.import_status    as enum ('preview', 'applied', 'rejected', 'stale');
create type app.package_kind     as enum ('master', 'jr');
create type app.evidence_kind    as enum (
  'assembly_photo', 'packing_photo', 'shipping_label', 'pickup_proof', 'delivery_proof',
  'incident_photo', 'other');
create type app.incident_status  as enum ('open', 'in_progress', 'resolved', 'cancelled');
create type app.invoice_status   as enum ('registered', 'pending_review', 'approved', 'paid', 'void');
create type app.notification_status as enum ('pending', 'sending', 'accepted', 'delivered', 'failed', 'bounced', 'suppressed');

-- ------------------------------------------------------------------ organizations / users
create table public.organizations (
  id         smallserial primary key,
  code       text not null unique check (code ~ '^[A-Z_]{2,20}$'),
  name       text not null,
  created_at timestamptz not null default now()
);

create table public.profiles (
  user_id    uuid primary key references auth.users(id) on delete restrict,
  email      text not null unique check (email = lower(email)),
  full_name  text not null default '',
  org_id     smallint not null references public.organizations(id),
  role       app.user_role not null,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ------------------------------------------------------------------ catalog
create table public.finishes (
  code     text primary key check (code = upper(code)),       -- as written in the source inventory (e.g. MATE)
  name_en  text not null,                                     -- public English label (editable by CESANTONI)
  name_es  text not null,
  verified boolean not null default false                     -- translation confirmed by CESANTONI
);

create table public.products (
  id          bigserial primary key,
  model       text not null unique check (model = upper(btrim(model)) and model <> ''),
  display_name_en text not null,
  description text,
  category    app.product_category not null default 'tile',
  status      app.record_status not null default 'active',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.variants (
  id             bigserial primary key,
  product_id     bigint not null references public.products(id),
  color_source   text,                      -- color exactly as in the source (NULL = model has no color name)
  color_en       text,                      -- public English color name
  finish_code    text not null references public.finishes(code),
  product_format text,                      -- format of the commercial product (NULL when not documented)
  status         app.record_status not null default 'active',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index variants_natural_key on public.variants (product_id, coalesce(color_source, ''), finish_code, coalesce(product_format, ''));

create table public.variant_images (
  id            bigserial primary key,
  variant_id    bigint not null references public.variants(id),
  storage_path  text not null,               -- path in the public "catalog-images" bucket (or absolute URL)
  source        text not null,               -- where the photo came from (cesantoni.com.mx, photo session…)
  kind          text not null default 'surface' check (kind in ('surface', 'ambient', 'detail')),
  is_primary    boolean not null default false,
  validated     boolean not null default false,
  validated_by  uuid references public.profiles(user_id),
  validated_at  timestamptz,
  notes         text,
  created_at    timestamptz not null default now(),
  check (not validated or (validated_by is not null and validated_at is not null))
);
create unique index variant_images_one_primary on public.variant_images (variant_id) where is_primary;

create table public.sample_skus (
  id               bigserial primary key,
  code             text not null unique check (code ~ '^[A-Z0-9][A-Z0-9._-]{2,40}$'),
  variant_id       bigint not null references public.variants(id),
  sample_type      app.sample_type not null,
  sample_size      text not null,            -- e.g. '20x20 cm / 8x8 in'
  sample_size_en   text not null,            -- public label e.g. '8x8 in cut sample'
  max_per_request  integer not null default 10 check (max_per_request between 1 and 500),
  public_enabled   boolean not null default false,  -- CESANTONI decides what is offered publicly
  catalog_verified boolean not null default false,  -- model/color/finish/size checked by CESANTONI
  source_ref       text,                     -- legacy reference (HOUSTON2-001…)
  status           app.record_status not null default 'active',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index sample_skus_variant_size on public.sample_skus (variant_id, sample_type, sample_size);

-- ------------------------------------------------------------------ warehouse
create table public.warehouses (
  id    smallserial primary key,
  code  text not null unique,
  name  text not null,
  timezone text not null default 'America/Chicago'
);

create table public.locations (
  id           bigserial primary key,
  warehouse_id smallint not null references public.warehouses(id),
  furniture    text not null,       -- "mueble"
  position     text not null,       -- kept as TEXT: 1.1 and 1.10 are different positions
  status       app.record_status not null default 'active',
  notes        text,
  unique (warehouse_id, furniture, position)
);

create table public.stock (
  id                bigserial primary key,
  sku_id            bigint not null references public.sample_skus(id),
  location_id       bigint references public.locations(id),   -- NULL = location not yet assigned
  on_hand           integer not null default 0 check (on_hand >= 0),
  reserved          integer not null default 0 check (reserved >= 0),
  validation_status app.stock_validation not null default 'pending_physical_validation',
  last_counted_at   timestamptz,
  version           bigint not null default 1,
  updated_at        timestamptz not null default now(),
  constraint stock_reserved_le_on_hand check (reserved <= on_hand)
);
create unique index stock_sku_location on public.stock (sku_id, coalesce(location_id, 0));
create index stock_location on public.stock (location_id);

-- one row per mutating operation (idempotency key → stored result)
create table public.operations (
  op_id      uuid primary key,
  kind       text not null,
  actor      uuid,
  actor_label text not null,
  created_at timestamptz not null default now(),
  result     jsonb
);

create table public.inventory_movements (
  id               bigserial primary key,
  op_id            uuid not null references public.operations(op_id),
  stock_id         bigint not null references public.stock(id),
  sku_id           bigint not null references public.sample_skus(id),
  location_id      bigint references public.locations(id),
  movement         app.movement_type not null,
  quantity         integer not null,          -- signed effect on the column it touches
  on_hand_before   integer not null,
  on_hand_after    integer not null check (on_hand_after >= 0),
  reserved_before  integer not null,
  reserved_after   integer not null check (reserved_after >= 0),
  request_id       bigint,                    -- FK added after requests table
  reason           text not null check (length(btrim(reason)) > 0),
  actor            uuid,
  actor_label      text not null,
  occurred_at      timestamptz not null default now(),
  recorded_at      timestamptz not null default now(),
  import_id        bigint
);
create index inventory_movements_sku on public.inventory_movements (sku_id, recorded_at desc);
create index inventory_movements_request on public.inventory_movements (request_id);
create unique index inventory_movements_op_stock_kind on public.inventory_movements (op_id, stock_id, movement);

-- ------------------------------------------------------------------ imports
create table public.imports (
  id            bigserial primary key,
  kind          app.import_kind not null,
  file_name     text not null,
  file_sha256   text not null check (file_sha256 ~ '^[0-9a-f]{64}$'),
  status        app.import_status not null default 'preview',
  reason        text,
  snapshot_hash text,               -- hash of the stock rows the preview was computed from
  rows_total    integer not null default 0,
  rows_valid    integer not null default 0,
  rows_rejected integer not null default 0,
  summary       jsonb not null default '{}'::jsonb,
  created_by    uuid,
  created_by_label text not null,
  created_at    timestamptz not null default now(),
  applied_by    uuid,
  applied_at    timestamptz,
  apply_op_id   uuid references public.operations(op_id)
);
-- the same file can never be applied twice for the same purpose
create unique index imports_file_once on public.imports (file_sha256, kind) where status = 'applied';

create table public.import_rows (
  id              bigserial primary key,
  import_id       bigint not null references public.imports(id),
  row_no          integer not null,
  raw             jsonb not null,
  sku_code        text,
  location_label  text,
  stock_id        bigint references public.stock(id),
  current_on_hand integer,
  current_reserved integer,
  proposed        integer,
  difference      integer,
  status          text not null check (status in ('valid', 'rejected', 'review')),
  message         text,
  unique (import_id, row_no)
);

-- movements recorded in the legacy spreadsheet: kept as history only, never re-applied
create table public.legacy_movements (
  id          bigserial primary key,
  source      text not null,
  source_row  integer not null,
  folio       text,
  reference   text,
  raw         jsonb not null,
  unique (source, source_row)
);

-- legacy references without SKU (kept for reconciliation, never summed automatically)
create table public.legacy_references (
  id          bigserial primary key,
  reference   text not null unique,
  source      text not null,
  raw         jsonb not null,
  note        text,
  resolved    boolean not null default false,
  resolved_sku_id bigint references public.sample_skus(id),
  created_at  timestamptz not null default now()
);

-- ------------------------------------------------------------------ requests
create sequence public.request_folio_seq start with 1 minvalue 1;

create table public.requests (
  id               bigserial primary key,
  folio_number     integer not null unique check (folio_number > 0),
  folio            text not null unique check (folio ~ '^SMCES-[0-9]{4,}$'),
  source           text not null default 'web' check (source in ('web', 'legacy_sheet', 'internal')),
  status           app.request_status not null default 'submitted',
  -- customer (snapshot as submitted)
  full_name        text not null check (length(btrim(full_name)) between 2 and 120),
  company          text,
  email            text not null check (email ~* '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$'),
  phone            text not null check (length(btrim(phone)) between 5 and 40),
  customer_user_id uuid references auth.users(id),
  delivery_method  app.delivery_method not null,
  address_line     text,
  city             text,
  state            text,
  zip_code         text,
  country          text,
  delivery_notes   text,
  project_name     text,
  notes            text,
  billing          jsonb,
  -- security / idempotency
  tracking_token_hash text not null,
  idempotency_key  uuid not null unique,
  client_fingerprint text,             -- hashed IP, never the raw IP
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint requests_shipping_address check (
    delivery_method = 'pickup' or source = 'legacy_sheet' or (
      coalesce(btrim(address_line), '') <> '' and coalesce(btrim(city), '') <> '' and
      coalesce(btrim(state), '') <> '' and coalesce(btrim(zip_code), '') <> '' and coalesce(btrim(country), '') <> ''))
);
create index requests_status on public.requests (status, created_at desc);
create index requests_email on public.requests (lower(email));

alter table public.inventory_movements
  add constraint inventory_movements_request_fk foreign key (request_id) references public.requests(id);
alter table public.inventory_movements
  add constraint inventory_movements_import_fk foreign key (import_id) references public.imports(id);

create table public.request_lines (
  id            bigserial primary key,
  request_id    bigint not null references public.requests(id),
  line_no       smallint not null check (line_no > 0),
  sku_id        bigint references public.sample_skus(id),   -- NULL only for unmatched legacy lines
  quantity      integer not null check (quantity > 0),
  -- historical snapshot (never rewritten when the catalog changes)
  snap_model    text not null,
  snap_color    text,
  snap_finish   text,
  snap_sample_size text,
  snap_sample_type text,
  snap_description text not null,
  legacy_raw    jsonb,
  unique (request_id, line_no)
);
create unique index request_lines_one_per_sku on public.request_lines (request_id, sku_id) where sku_id is not null;

create table public.reservations (
  id              bigserial primary key,
  request_id      bigint not null references public.requests(id),
  request_line_id bigint not null references public.request_lines(id),
  stock_id        bigint not null references public.stock(id),
  quantity        integer not null check (quantity > 0),
  status          app.reservation_status not null default 'active',
  created_at      timestamptz not null default now(),
  closed_at       timestamptz,
  closed_op_id    uuid references public.operations(op_id),
  check ((status = 'active') = (closed_at is null))
);
create index reservations_request on public.reservations (request_id, status);
create index reservations_stock_active on public.reservations (stock_id) where status = 'active';

create table public.request_status_history (
  id           bigserial primary key,
  request_id   bigint not null references public.requests(id),
  from_status  app.request_status,
  to_status    app.request_status not null,
  reason       text,
  is_exception boolean not null default false,
  actor        uuid,
  actor_label  text not null,
  op_id        uuid references public.operations(op_id),
  occurred_at  timestamptz not null,           -- when it happened
  recorded_at  timestamptz not null default now(), -- when it was captured
  retroactive  boolean generated always as (recorded_at - occurred_at > interval '15 minutes') stored
);
create index request_status_history_req on public.request_status_history (request_id, recorded_at);

-- ------------------------------------------------------------------ packing / shipping
create table public.packages (
  id          bigserial primary key,
  request_id  bigint not null references public.requests(id),
  kind        app.package_kind not null,
  parent_id   bigint references public.packages(id),    -- JR card inside a Master box
  code        text not null unique,                     -- human readable: SMCES-0013-M01 / SMCES-0013-M01-J02
  seq         smallint not null check (seq > 0),
  qr_token    text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  prep_location text,
  verified_at timestamptz,
  verified_by uuid,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  voided      boolean not null default false,
  check ((kind = 'master') = (parent_id is null))
);
create unique index packages_seq on public.packages (request_id, kind, coalesce(parent_id, 0), seq);

create table public.package_items (
  id              bigserial primary key,
  package_id      bigint not null references public.packages(id),
  request_line_id bigint not null references public.request_lines(id),
  quantity        integer not null check (quantity > 0),
  unique (package_id, request_line_id)
);

create table public.shipments (
  id            bigserial primary key,
  request_id    bigint not null references public.requests(id),
  carrier       text not null check (carrier ~ '^[A-Z0-9 ]{2,30}$'),
  tracking_no   text not null check (tracking_no ~ '^[A-Z0-9-]{6,40}$'),
  label_created_at timestamptz,
  handed_over_at   timestamptz,            -- delivered to the carrier
  delivered_at     timestamptz,
  cost_usd      numeric(12,2) check (cost_usd is null or cost_usd >= 0),
  status        text not null default 'label_created' check (status in ('label_created', 'in_transit', 'delivered', 'exception', 'void')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (request_id, carrier, tracking_no)
);
create index shipments_request on public.shipments (request_id);
-- one tracking number may cover several requests (consolidated shipment), but its cost is recorded only once
create unique index shipments_cost_once on public.shipments (carrier, tracking_no) where cost_usd is not null and status <> 'void';

create table public.incidents (
  id           bigserial primary key,
  request_id   bigint not null references public.requests(id),
  package_id   bigint references public.packages(id),
  description  text not null check (length(btrim(description)) > 3),
  status       app.incident_status not null default 'open',
  owner_org    smallint references public.organizations(id),
  resolution   text,
  opened_by    uuid,
  opened_at    timestamptz not null default now(),
  resolved_by  uuid,
  resolved_at  timestamptz,
  check ((status in ('resolved', 'cancelled')) = (resolved_at is not null))
);

create table public.evidences (
  id            bigserial primary key,
  request_id    bigint not null references public.requests(id),
  package_id    bigint references public.packages(id),
  shipment_id   bigint references public.shipments(id),
  incident_id   bigint references public.incidents(id),
  kind          app.evidence_kind not null,
  storage_path  text not null unique,     -- private bucket "evidence"
  mime_type     text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf')),
  size_bytes    integer not null check (size_bytes between 1 and 15728640),
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  uploaded_by   uuid not null,
  uploaded_at   timestamptz not null default now(),
  event_at      timestamptz,
  notes         text,
  voided        boolean not null default false,   -- evidence is never deleted; it is voided with a reason
  void_reason   text,
  voided_by     uuid,
  voided_at     timestamptz,
  replaced_by   bigint references public.evidences(id),
  check (not voided or (void_reason is not null and voided_at is not null))
);
create unique index evidences_same_file_once on public.evidences (request_id, sha256) where not voided;

-- ------------------------------------------------------------------ billing
create table public.invoices (
  id           bigserial primary key,
  issuer       text not null,
  receiver     text not null,
  number       text not null,
  issue_date   date not null,
  concept      text not null,
  currency     char(3) not null check (currency ~ '^[A-Z]{3}$'),
  subtotal     numeric(14,2) not null check (subtotal >= 0),
  tax          numeric(14,2) not null default 0 check (tax >= 0),
  total        numeric(14,2) not null check (total >= 0),
  status       app.invoice_status not null default 'registered',
  notes        text,
  created_by   uuid not null,
  created_at   timestamptz not null default now(),
  updated_by   uuid,
  updated_at   timestamptz not null default now(),
  check (total = subtotal + tax)
);
create unique index invoices_issuer_number on public.invoices (upper(btrim(issuer)), upper(btrim(number)));

create table public.invoice_requests (
  invoice_id bigint not null references public.invoices(id),
  request_id bigint not null references public.requests(id),
  primary key (invoice_id, request_id)
);
-- a shipping cost can be billed by only one invoice line
create table public.invoice_shipments (
  invoice_id  bigint not null references public.invoices(id),
  shipment_id bigint not null unique references public.shipments(id),
  amount_usd  numeric(12,2) not null check (amount_usd >= 0),
  primary key (invoice_id, shipment_id)
);
create table public.invoice_documents (
  id           bigserial primary key,
  invoice_id   bigint not null references public.invoices(id),
  storage_path text not null unique,   -- private bucket "invoices"
  doc_type     text not null check (doc_type in ('pdf', 'xml', 'other')),
  mime_type    text not null,
  size_bytes   integer not null check (size_bytes between 1 and 15728640),
  sha256       text not null,
  uploaded_by  uuid not null,
  uploaded_at  timestamptz not null default now(),
  voided       boolean not null default false,
  void_reason  text
);

-- ------------------------------------------------------------------ notifications
create table public.notification_recipients (
  id        bigserial primary key,
  event     text not null,
  org_id    smallint not null references public.organizations(id),
  email     text not null check (email = lower(email) and email ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$'),
  active    boolean not null default true,
  unique (event, email)
);

create table public.notifications (
  id            bigserial primary key,
  event         text not null,
  request_id    bigint references public.requests(id),
  recipient     text not null,
  audience      text not null check (audience in ('customer', 'internal')),
  template      text not null,
  payload       jsonb not null default '{}'::jsonb,
  dedupe_key    text not null unique,        -- same event + recipient is never queued twice
  status        app.notification_status not null default 'pending',
  attempts      integer not null default 0,
  max_attempts  integer not null default 6,
  next_attempt_at timestamptz not null default now(),
  locked_until  timestamptz,
  provider_id   text,
  last_error    text,
  created_at    timestamptz not null default now(),
  accepted_at   timestamptz,
  delivered_at  timestamptz
);
create index notifications_due on public.notifications (next_attempt_at) where status in ('pending', 'failed');

-- ------------------------------------------------------------------ audit / settings / rate limit
create table public.audit_log (
  id          bigserial primary key,
  table_name  text not null,
  record_id   text not null,
  action      text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_values  jsonb,
  new_values  jsonb,
  actor       uuid,
  actor_label text,
  at          timestamptz not null default now()
);
create index audit_log_record on public.audit_log (table_name, record_id, at desc);

create table public.settings (
  key        text primary key,
  value      jsonb not null,
  description text not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

create table app.rate_limits (
  bucket       text not null,
  window_start timestamptz not null,
  hits         integer not null default 0,
  primary key (bucket, window_start)
);

-- ------------------------------------------------------------------ derived view
create view public.stock_overview with (security_invoker = true) as
select s.id as stock_id, k.id as sku_id, k.code as sku_code, p.model, v.color_source, v.color_en,
       f.code as finish_code, f.name_en as finish_en, k.sample_type, k.sample_size, k.sample_size_en,
       l.furniture, l.position, w.code as warehouse,
       s.on_hand, s.reserved, (s.on_hand - s.reserved) as available,
       s.validation_status, s.last_counted_at, k.public_enabled, k.catalog_verified, s.updated_at
from public.stock s
join public.sample_skus k on k.id = s.sku_id
join public.variants v on v.id = k.variant_id
join public.products p on p.id = v.product_id
join public.finishes f on f.code = v.finish_code
left join public.locations l on l.id = s.location_id
left join public.warehouses w on w.id = l.warehouse_id;

-- ===================================================== 20261104000200_security.sql
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
    -- RLS applies to anon/authenticated. Not FORCED: the SECURITY DEFINER functions (owned by the
    -- migration role) must be able to write; they enforce permissions themselves (app.require_role).
    execute format('alter table public.%I enable row level security', t);
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

-- ===================================================== 20261104000300_inventory.sql
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

-- ===================================================== 20261104000400_requests.sql
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

-- ===================================================== 20261104000500_operations_billing.sql
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

-- ===================================================== 20261104000600_public_notifications_dashboard.sql
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
   where folio = upper(btrim(p_folio)) and tracking_token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
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

-- ===================================================== 20261104000700_reference_data.sql
-- Reference data that the platform needs to start (no inventory, no customers).
insert into public.organizations (code, name) values
  ('CESANTONI', 'CESANTONI'), ('ARMEX', 'ARMEX Logistics'), ('CLIENT', 'Customers')
on conflict (code) do nothing;

insert into public.warehouses (code, name, timezone) values ('HOUSTON', 'ARMEX Houston', 'America/Chicago')
on conflict (code) do nothing;

-- Finishes as written in the Houston inventory. English labels are PROPOSALS (verified = false)
-- until CESANTONI confirms them in the panel.
insert into public.finishes (code, name_es, name_en, verified) values
  ('MATE', 'Mate', 'Matte', false),
  ('GRIP', 'Grip', 'Grip', false),
  ('RIGATO', 'Rigato', 'Rigato', false),
  ('BRILLANTE', 'Brillante', 'Glossy', false),
  ('PULIDO BRILLANTE', 'Pulido brillante', 'Polished', false),
  ('PULIDO MATE', 'Pulido mate', 'Matte Polished', false),
  ('SATINADO', 'Satinado', 'Satin', false),
  ('VELVET FINISH', 'Velvet', 'Velvet', false),
  ('GLOW', 'Glow', 'Glow', false)
on conflict (code) do nothing;

-- ===================================================== 20261104000800_public_submit.sql
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
