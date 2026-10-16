-- =====================================================================
-- ServicePro — core schema
-- Target: Supabase (PostgreSQL 15+). auth.users is provided by Supabase.
--
-- Design notes (deviations from the original outline, on purpose):
--  * Every id is a UUID the phone can generate itself, so the tech app
--    can work offline in walk-ins/basements and sync later without
--    creating duplicates.
--  * Customers have SITES (stores). Geofence lives on the site.
--  * PO cap lives on the work order; cap increases are APPROVALS rows.
--  * Repair types carry the expected cost/labor/parts ranges that the
--    guardrail engine checks against.
--  * Timestamps can only be corrected through an override that is
--    logged (who, when, why, old value, new value).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Enums ----------------------------------------------------
create type user_role        as enum ('technician','contractor_admin','dispatcher','customer_admin','customer_user','platform_admin');
create type wo_status        as enum ('created','assigned','en_route','on_site','awaiting_approval','completed','invoiced','cancelled');
create type equipment_type   as enum ('rack','condenser','evaporator','walk_in_cooler','walk_in_freezer','reach_in','display_case','make_table','ice_machine','rtu','furnace','split_system','exhaust_hood','water_heater','other');
create type photo_kind       as enum ('equipment','nameplate','part','before','after','other');
create type part_source      as enum ('truck','wholesale','customer_supplied');
create type gps_event        as enum ('ping','en_route','arrived','departed','geofence_enter','geofence_exit','completed');
create type flag_type        as enum ('underbilling','overbilling','parts_missing','parts_excessive','labor_out_of_range','po_near_cap','po_exceeded','time_override','gps_mismatch');
create type approval_status  as enum ('pending','approved','declined');
create type notify_type      as enum ('eta_update','arrival','approval_request','approval_granted','approval_declined','guardrail_flag','completed');
create type org_kind         as enum ('contractor','customer');

-- ---------- Organizations --------------------------------------------
create table contractors (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  phone                 text,
  email                 text,
  -- pricing rules
  labor_rate            numeric(10,2) not null default 125.00,   -- $/hour
  min_labor_minutes     int           not null default 60,       -- minimum billed labor
  labor_increment_min   int           not null default 15,       -- round labor up to this
  bill_travel_time      boolean       not null default false,    -- bill started->arrived?
  trip_charge           numeric(10,2) not null default 0,
  parts_markup_pct      numeric(5,2)  not null default 0,        -- applied when price not set
  po_warn_pct           numeric(5,2)  not null default 80,       -- alert at this % of cap
  -- QuickBooks
  qbo_realm_id          text,
  qbo_connected_at      timestamptz,
  created_at            timestamptz not null default now()
);

create table customers (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  phone                 text,
  email                 text,
  created_at            timestamptz not null default now()
);

-- Which contractors are allowed to work for which customers.
create table service_agreements (
  contractor_id         uuid not null references contractors(id) on delete cascade,
  customer_id           uuid not null references customers(id)   on delete cascade,
  qbo_customer_ref      text,          -- QuickBooks customer id for invoices
  default_po_cap        numeric(10,2), -- optional default cap for new calls
  created_at            timestamptz not null default now(),
  primary key (contractor_id, customer_id)
);

create table sites (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references customers(id) on delete cascade,
  name                  text not null,               -- "Store #114"
  address               text not null,
  lat                   double precision,
  lon                   double precision,
  geofence_radius_ft    int not null default 250 check (geofence_radius_ft between 50 and 2000),
  access_notes          text,                        -- "roof ladder behind dairy"
  created_at            timestamptz not null default now()
);

-- ---------- People ---------------------------------------------------
-- One row per login. id = auth.users.id
create table profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  role                  user_role not null,
  full_name             text not null,
  phone                 text,
  email                 text,
  contractor_id         uuid references contractors(id),
  customer_id           uuid references customers(id),
  hourly_cost           numeric(10,2),     -- optional, for margin reporting later
  active                boolean not null default true,
  created_at            timestamptz not null default now(),
  constraint profile_org check (
    (role in ('technician','contractor_admin','dispatcher') and contractor_id is not null and customer_id is null) or
    (role in ('customer_admin','customer_user')              and customer_id   is not null and contractor_id is null) or
    (role = 'platform_admin')
  )
);

-- ---------- Equipment ------------------------------------------------
create table equipment (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references customers(id) on delete cascade,
  site_id               uuid not null references sites(id) on delete cascade,
  type                  equipment_type not null default 'other',
  manufacturer          text,
  model                 text,
  serial                text,
  refrigerant           text,
  location_description  text,         -- "Roof, rack B", "Aisle 7 dairy case"
  install_date          date,
  identity_confirmed    boolean not null default false,  -- tech confirmed model/serial
  confirmed_by          uuid references profiles(id),
  confirmed_at          timestamptz,
  created_at            timestamptz not null default now()
);
create unique index equipment_serial_unique on equipment (site_id, lower(manufacturer), lower(serial))
  where serial is not null and manufacturer is not null;

-- ---------- Parts & repair templates ---------------------------------
create table parts (
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid not null references contractors(id) on delete cascade,
  sku                   text not null,
  name                  text not null,
  category              text,
  barcode               text,
  unit_cost             numeric(10,2),        -- what the contractor pays
  unit_price            numeric(10,2),        -- what the customer is billed (null = cost + markup)
  reference_photo_path  text,
  active                boolean not null default true,
  unique (contractor_id, sku)
);

create table repair_types (
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid not null references contractors(id) on delete cascade,
  name                  text not null,                 -- "Replace condenser fan motor"
  summary_template      text not null,                 -- used to auto-write the work summary
  applies_to            equipment_type[],              -- null = any
  parts_required        boolean not null default true, -- false for e.g. "Clean condenser coil"
  expected_cost_min     numeric(10,2),
  expected_cost_max     numeric(10,2),
  expected_labor_min    int,                           -- minutes
  expected_labor_max    int,
  active                boolean not null default true,
  unique (contractor_id, name)
);

-- The pre-canned kit for a repair type
create table repair_type_parts (
  repair_type_id        uuid not null references repair_types(id) on delete cascade,
  part_id               uuid not null references parts(id) on delete cascade,
  quantity              numeric(10,2) not null default 1,
  primary key (repair_type_id, part_id)
);

-- ---------- Work orders ----------------------------------------------
create sequence work_order_number_seq start 1001;

create table work_orders (
  id                    uuid primary key default gen_random_uuid(),
  number                bigint not null unique default nextval('work_order_number_seq'),
  contractor_id         uuid not null references contractors(id),
  customer_id           uuid not null references customers(id),
  site_id               uuid not null references sites(id),
  equipment_id          uuid references equipment(id),
  technician_id         uuid references profiles(id),
  repair_type_id        uuid references repair_types(id),
  status                wo_status not null default 'created',
  priority              smallint not null default 2 check (priority between 1 and 3), -- 1 = emergency
  issue_description     text not null,
  work_summary          text,          -- auto-generated, tech can accept as-is
  no_parts_used         boolean not null default false, -- tech explicitly tapped "No parts used"
  scheduled_for         timestamptz,
  estimated_minutes     int,
  eta_at                timestamptz,   -- expected arrival, reported by the tech's phone
  -- PO / cost control
  po_number             text,
  po_cap                numeric(10,2) check (po_cap is null or po_cap > 0),
  -- immutable lifecycle timestamps (set only by functions)
  created_by            uuid references profiles(id),
  created_at            timestamptz not null default now(),
  assigned_at           timestamptz,
  started_at            timestamptz,
  arrived_at            timestamptz,
  departed_at           timestamptz,
  completed_at          timestamptz,
  cancelled_at          timestamptz,
  -- costs (set only by recalc function)
  labor_minutes_billed  int not null default 0,
  total_parts           numeric(10,2) not null default 0,
  total_labor           numeric(10,2) not null default 0,
  total_trip            numeric(10,2) not null default 0,
  total_cost            numeric(10,2) not null default 0,
  -- billing
  invoice_ready         boolean not null default false,  -- true when completed with no open flags
  qbo_invoice_id        text,
  exported_at           timestamptz,
  updated_at            timestamptz not null default now()
);
create index on work_orders (contractor_id, status);
create index on work_orders (customer_id, status);
create index on work_orders (technician_id, status);
create index on work_orders (equipment_id);

create table photos (
  id                    uuid primary key default gen_random_uuid(),  -- generated on the phone
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  equipment_id          uuid references equipment(id),
  part_id               uuid references parts(id),
  kind                  photo_kind not null,
  storage_path          text not null,           -- path in Supabase Storage bucket "photos"
  taken_at              timestamptz not null,    -- device clock at capture
  lat                   double precision,
  lon                   double precision,
  ai_result             jsonb,                   -- raw AI extraction (model/serial/part guess)
  uploaded_by           uuid not null references profiles(id),
  uploaded_at           timestamptz not null default now()
);
create index on photos (work_order_id, kind);

create table parts_used (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  part_id               uuid not null references parts(id),
  quantity              numeric(10,2) not null check (quantity > 0),
  source                part_source not null default 'truck',
  unit_price            numeric(10,2) not null,   -- snapshot at time of use
  total_price           numeric(10,2) generated always as (round(quantity * unit_price, 2)) stored,
  added_by              uuid references profiles(id),
  added_at              timestamptz not null default now(),
  unique (work_order_id, part_id, source)
);

-- Append-only location trail
create table gps_logs (
  id                    bigint generated always as identity primary key,
  technician_id         uuid not null references profiles(id),
  work_order_id         uuid references work_orders(id) on delete cascade,
  lat                   double precision not null,
  lon                   double precision not null,
  accuracy_m            real,
  event                 gps_event not null default 'ping',
  recorded_at           timestamptz not null,           -- device time
  received_at           timestamptz not null default now()
);
create index on gps_logs (technician_id, recorded_at desc);
create index on gps_logs (work_order_id, recorded_at);

-- Cost-increase approvals (PO cap raises)
create table approvals (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  requested_by          uuid not null references profiles(id),
  requested_amount      numeric(10,2) not null check (requested_amount > 0), -- additional $ above cap
  reason                text not null,
  status                approval_status not null default 'pending',
  decided_by            uuid references profiles(id),
  decided_at            timestamptz,
  created_at            timestamptz not null default now()
);
create index on approvals (work_order_id, status);

create table guardrail_flags (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  flag                  flag_type not null,
  description           text not null,
  blocking              boolean not null default true,   -- blocks invoicing until resolved
  triggered_at          timestamptz not null default now(),
  resolved_at           timestamptz,
  resolved_by           uuid references profiles(id),
  resolution_note       text
);
create unique index guardrail_one_open on guardrail_flags (work_order_id, flag) where resolved_at is null;

-- Logged corrections to lifecycle timestamps (GPS failure, dead phone, etc.)
create table time_overrides (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  field                 text not null check (field in ('started_at','arrived_at','departed_at','completed_at')),
  old_value             timestamptz,
  new_value             timestamptz not null,
  reason                text not null check (length(reason) >= 10),
  overridden_by         uuid not null references profiles(id),
  overridden_at         timestamptz not null default now()
);

create table notifications (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references profiles(id) on delete cascade,
  work_order_id         uuid references work_orders(id) on delete cascade,
  type                  notify_type not null,
  message               text not null,
  created_at            timestamptz not null default now(),
  sent_at               timestamptz,   -- set by the push/SMS/email worker
  read_at               timestamptz
);
create index on notifications (user_id, read_at);

-- ---------- Platform fees ($5/call with monthly cap) ------------------
create table fee_plans (
  org_kind              org_kind not null,
  org_id                uuid not null,
  per_call              numeric(10,2) not null default 5.00,
  monthly_cap           numeric(10,2),          -- null = no cap (enterprise per-call pricing)
  primary key (org_kind, org_id)
);

create table platform_fees (
  id                    uuid primary key default gen_random_uuid(),
  org_kind              org_kind not null,
  org_id                uuid not null,
  work_order_id         uuid not null references work_orders(id),
  billing_month         date not null,          -- first day of month
  amount                numeric(10,2) not null, -- 0 once the cap is reached
  created_at            timestamptz not null default now(),
  unique (org_kind, org_id, work_order_id)
);

-- ---------- Audit trail ----------------------------------------------
create table audit_log (
  id                    bigint generated always as identity primary key,
  table_name            text not null,
  row_id                uuid,
  action                text not null,
  actor                 uuid,
  old_data              jsonb,
  new_data              jsonb,
  at                    timestamptz not null default now()
);
create index on audit_log (table_name, row_id);
