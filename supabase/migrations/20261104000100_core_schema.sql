-- =====================================================================================
-- CESANTONI · ARMEX Samples Platform — core schema (v1)
-- Single source of truth for catalog, inventory, requests, operations and billing.
-- Rules enforced by the database (not only by the UI):
--   * no negative stock or reservations, reserved <= on_hand  (available = on_hand - reserved)
--   * movements and status history are append-only
--   * request lines keep a historical snapshot (renaming a product never rewrites old requests)
--   * every mutating operation carries an operation id (idempotency against double click / retries)
-- =====================================================================================
create extension if not exists pgcrypto;

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
  qr_token    text not null unique default encode(gen_random_bytes(16), 'hex'),
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
