-- =====================================================================
-- ServicePro v2 — tables
-- Target: Supabase (PostgreSQL 15+). auth.users is provided by Supabase.
--
-- Shape of the system
--   customers (stores / homeowners) ── sites ── equipment
--   contractors ── technicians, office staff
--   work_orders (a JOB) ── visits (each trip) ── photos, parts_used, gps
--                       └─ po_lines (PO1100, PO1100A, B, C…)
--   pm_plans → generate PM work orders; agreements → coverage & response times
--   warranties, parts_orders, time_entries, platform_fees, wholesalers
-- Every id is a UUID the phone can create offline.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Enums ----------------------------------------------------
create type org_kind        as enum ('contractor','customer','wholesaler');
create type customer_kind   as enum ('commercial','residential');
create type wo_kind         as enum ('service','pm','install','estimate');
create type wo_status       as enum ('created','assigned','en_route','on_site','awaiting_approval',
                                     'waiting_parts','return_needed','completed','invoiced','cancelled');
create type visit_status    as enum ('assigned','en_route','on_site','done','cancelled');
create type visit_outcome   as enum ('completed','parts_needed','return_needed','quote_needed');
create type photo_kind      as enum ('equipment','nameplate','part','before','after','checklist','other');
create type part_source     as enum ('truck','wholesale','customer_supplied');
create type gps_event       as enum ('ping','en_route','arrived','departed','geofence_enter','geofence_exit','completed');
create type po_line_kind    as enum ('diagnosis','repair','additional','parts_price','after_hours','pm','install','other');
create type approval_status as enum ('pending','approved','declined');
create type flag_type       as enum ('underbilling','overbilling','parts_missing','parts_excessive','labor_out_of_range',
                                     'po_near_cap','po_exceeded','time_override','gps_mismatch','checkin_unverified',
                                     'billing_late');
create type notify_type     as enum ('new_call','assigned','eta_update','eta_close','arrival','departure','checkin',
                                     'approval_request','approval_granted','approval_declined','guardrail_flag',
                                     'parts_waiting','completed','pm_due','pm_overdue','billing_due','billing_overdue',
                                     'warranty','sla_missed');
create type checkin_method  as enum ('code','backup_code','name_only');
create type coverage_kind   as enum ('pm_only','pm_labor','full');
create type fee_interval    as enum ('monthly','quarterly','annual');
create type parts_order_status as enum ('needed','ordered','received','cancelled');
create type time_kind       as enum ('shift','break');
create type store_plan      as enum ('store','store_multi');
create type contractor_plan as enum ('base','pro','enterprise');

-- ---------- Platform catalog (maintained by us) ----------------------
create table trades (
  id                    smallint primary key,
  code                  text not null unique,
  name                  text not null
);

-- Platform defaults have contractor_id null; contractors may add their own.
create table equipment_types (
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid,                      -- FK added after contractors exists
  trade_id              smallint references trades(id),
  code                  text not null,
  name                  text not null,
  unique nulls not distinct (contractor_id, code)
);

create table cost_regions (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null unique,      -- "Los Angeles metro"
  adjust_pct            numeric(6,2) not null default 0   -- +40 = 40% higher
);

-- First 3 digits of a ZIP → region (US ZIP3 is a natural regional grouping)
create table region_zip3 (
  zip3                  char(3) primary key,
  region_id             uuid not null references cost_regions(id) on delete cascade
);

-- The store's dropdown: "Walk-in freezer down" → diagnosis amount + priority
create table issue_types (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique,
  name                  text not null,
  trade_id              smallint references trades(id),
  equipment_type_code   text,                      -- suggested equipment type
  diagnosis_amount      numeric(10,2) not null check (diagnosis_amount > 0),
  priority              smallint not null default 2 check (priority between 1 and 3),
  for_commercial        boolean not null default true,
  for_residential       boolean not null default false,
  sort                  int not null default 100,
  active                boolean not null default true
);

-- Single-row platform settings
create table platform_settings (
  id                    boolean primary key default true check (id),
  after_hours_pct       numeric(6,2) not null default 50,    -- +50% nights/weekends/holidays
  business_start        time not null default '07:00',
  business_end          time not null default '17:00',
  business_tz           text not null default 'America/Chicago',
  store_fee_per_po      numeric(10,2) not null default 5,
  store_fee_per_pm      numeric(10,2) not null default 3,
  contractor_fee_per_po numeric(10,2) not null default 5,
  contractor_fee_per_pm numeric(10,2) not null default 3,
  contractor_cap_per_tech numeric(10,2) not null default 40,
  store_multi_per_location numeric(10,2) not null default 29,
  pro_per_tech          numeric(10,2) not null default 25,
  default_billing_days  int not null default 7,
  billing_reminder_days int not null default 5,
  default_eta_alert_min int not null default 5
);
insert into platform_settings default values;

create table holidays (
  day                   date primary key,
  name                  text not null
);

-- ---------- Organizations --------------------------------------------
create table wholesalers (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  invite_code           text not null unique,
  commission_pct        numeric(5,2) not null default 15 check (commission_pct between 0 and 50),
  stripe_account_id     text,
  created_at            timestamptz not null default now()
);

create table contractors (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  phone                 text,
  email                 text,
  plan                  contractor_plan not null default 'base',
  fees_waived_until     date,                      -- pilot: free period
  -- pricing rules
  labor_rate            numeric(10,2) not null default 125.00,
  after_hours_labor_rate numeric(10,2),
  min_labor_minutes     int  not null default 60,
  labor_increment_min   int  not null default 15,
  bill_travel_time      boolean not null default false,
  trip_charge           numeric(10,2) not null default 0,
  parts_markup_pct      numeric(5,2) not null default 0,
  po_warn_pct           numeric(5,2) not null default 80,
  billing_days          int,                       -- null = platform default (7)
  timezone              text not null default 'America/Chicago',   -- for timecard days
  -- QuickBooks
  qbo_realm_id          text,
  qbo_connected_at      timestamptz,
  created_at            timestamptz not null default now()
);
alter table equipment_types add constraint equipment_types_contractor_fk
  foreign key (contractor_id) references contractors(id) on delete cascade;

create table customers (
  id                    uuid primary key default gen_random_uuid(),
  name                  text not null,
  kind                  customer_kind not null default 'commercial',
  phone                 text,
  email                 text,
  plan                  store_plan not null default 'store',
  fees_waived_until     date,
  wholesaler_id         uuid references wholesalers(id),
  letter_escalation_at  int not null default 3,    -- 3 = from letter C, route to step 2+
  created_at            timestamptz not null default now()
);

create table customer_contractors (                -- which contractors serve which customers
  contractor_id         uuid not null references contractors(id) on delete cascade,
  customer_id           uuid not null references customers(id) on delete cascade,
  qbo_customer_ref      text,
  is_primary            boolean not null default true,
  created_at            timestamptz not null default now(),
  primary key (contractor_id, customer_id)
);

create table sites (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references customers(id) on delete cascade,
  name                  text not null,
  address               text not null,
  zip                   text,
  region_id             uuid references cost_regions(id),   -- override; else from ZIP
  lat                   double precision,
  lon                   double precision,
  geofence_radius_ft    int not null default 250 check (geofence_radius_ft between 50 and 2000),
  access_notes          text,
  require_checkin       boolean not null default false,     -- meet-on-site default
  require_checkout      boolean not null default false,
  backup_code_hash      text,                                -- store's standing backup code
  eta_alert_minutes     int,                                 -- null = platform default (5)
  timezone              text not null default 'America/Chicago',
  created_at            timestamptz not null default now()
);

-- ---------- People ---------------------------------------------------
-- One row per login (id = auth.users.id). Title is free text in the
-- organization's own words; what they can DO is the permission flags.
create table profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  org_kind              org_kind,                  -- null + is_platform_admin for us
  contractor_id         uuid references contractors(id),
  customer_id           uuid references customers(id),
  wholesaler_id         uuid references wholesalers(id),
  full_name             text not null,
  title                 text,                      -- "Maintenance Manager"
  email                 text,
  phone                 text,
  active                boolean not null default true,
  is_platform_admin     boolean not null default false,
  is_org_admin          boolean not null default false,   -- manage users & settings
  -- contractor-side
  is_technician         boolean not null default false,
  can_dispatch          boolean not null default false,
  can_bill              boolean not null default false,
  hourly_cost           numeric(10,2),             -- for job costing
  -- customer-side
  can_open_calls        boolean not null default false,
  can_approve           boolean not null default false,
  approval_limit        numeric(10,2),             -- null = no limit
  can_manage_pm         boolean not null default false,
  can_see_billing       boolean not null default false,
  all_sites             boolean not null default true,    -- false → only profile_sites
  -- what to be told about
  notify                jsonb not null default
    '{"new_call":true,"assigned":true,"eta_update":true,"eta_close":true,"arrival":true,"departure":true,
      "checkin":true,"approval_request":true,"approval_granted":true,"approval_declined":true,
      "guardrail_flag":true,"parts_waiting":true,"completed":true,"pm_due":true,"pm_overdue":true,
      "billing_due":true,"billing_overdue":true,"warranty":true,"sla_missed":true}'::jsonb,
  created_at            timestamptz not null default now(),
  constraint profile_org check (
    (org_kind = 'contractor' and contractor_id is not null and customer_id is null and wholesaler_id is null) or
    (org_kind = 'customer'   and customer_id   is not null and contractor_id is null and wholesaler_id is null) or
    (org_kind = 'wholesaler' and wholesaler_id is not null and contractor_id is null and customer_id is null) or
    (org_kind is null and is_platform_admin))
);

create table profile_sites (
  profile_id            uuid not null references profiles(id) on delete cascade,
  site_id               uuid not null references sites(id) on delete cascade,
  primary key (profile_id, site_id)
);

-- Pending invitations (the org admin invites by email)
create table invitations (
  id                    uuid primary key default gen_random_uuid(),
  email                 text not null,
  template              jsonb not null,            -- the profile fields to apply
  site_ids              uuid[] not null default '{}',
  invited_by            uuid not null references profiles(id),
  created_at            timestamptz not null default now(),
  accepted_at           timestamptz
);

-- ---------- Approval escalation chains (customer edits these) --------
create table approval_chains (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references customers(id) on delete cascade,
  name                  text not null,
  all_sites             boolean not null default true,
  timeout_minutes       int not null default 30 check (timeout_minutes between 5 and 1440),
  emergency_profile_id  uuid references profiles(id),   -- priority-1 goes straight here
  created_at            timestamptz not null default now()
);
create table approval_chain_sites (
  chain_id              uuid not null references approval_chains(id) on delete cascade,
  site_id               uuid not null references sites(id) on delete cascade,
  primary key (chain_id, site_id)
);
create table approval_chain_steps (
  chain_id              uuid not null references approval_chains(id) on delete cascade,
  step_no               int not null check (step_no >= 1),
  profile_id            uuid not null references profiles(id),
  backup_profile_id     uuid references profiles(id),
  primary key (chain_id, step_no)
);

-- ---------- Equipment ------------------------------------------------
create table equipment (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references customers(id) on delete cascade,
  site_id               uuid not null references sites(id) on delete cascade,
  equipment_type_id     uuid references equipment_types(id),
  manufacturer          text,
  model                 text,
  serial                text,
  refrigerant           text,
  location_description  text,
  install_date          date,
  identity_confirmed    boolean not null default false,
  confirmed_by          uuid references profiles(id),
  confirmed_at          timestamptz,
  created_at            timestamptz not null default now()
);
create unique index equipment_serial_unique on equipment (site_id, lower(manufacturer), lower(serial))
  where serial is not null and manufacturer is not null and upper(serial) <> 'UNREADABLE';

-- ---------- Contractor catalog ---------------------------------------
create table parts (
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid not null references contractors(id) on delete cascade,
  sku                   text not null,
  name                  text not null,
  category              text,
  barcode               text,
  unit_cost             numeric(10,2),
  unit_price            numeric(10,2),
  reference_photo_path  text,
  active                boolean not null default true,
  unique (contractor_id, sku)
);

create table warranty_terms (                      -- the closeout dropdown
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid not null references contractors(id) on delete cascade,
  name                  text not null,             -- "90-day labor / 1-year parts"
  labor_days            int not null default 0,
  parts_days            int not null default 0,
  sort                  int not null default 100,
  unique (contractor_id, name)
);

create table repair_types (
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid not null references contractors(id) on delete cascade,
  trade_id              smallint references trades(id),
  name                  text not null,
  summary_template      text not null,
  equipment_type_codes  text[],                    -- null = any
  parts_required        boolean not null default true,
  default_warranty_id   uuid references warranty_terms(id),
  expected_cost_min     numeric(10,2),
  expected_cost_max     numeric(10,2),
  expected_labor_min    int,
  expected_labor_max    int,
  active                boolean not null default true,
  unique (contractor_id, name)
);

create table repair_type_parts (
  repair_type_id        uuid not null references repair_types(id) on delete cascade,
  part_id               uuid not null references parts(id) on delete cascade,
  quantity              numeric(10,2) not null default 1,
  primary key (repair_type_id, part_id)
);

-- ---------- Maintenance agreements -----------------------------------
create table agreements (
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid not null references contractors(id) on delete cascade,
  customer_id           uuid not null references customers(id) on delete cascade,
  name                  text not null,
  starts_on             date not null,
  ends_on               date not null check (ends_on > starts_on),
  all_sites             boolean not null default true,
  coverage              coverage_kind not null default 'pm_only',
  fee_amount            numeric(10,2) not null default 0,
  fee_interval          fee_interval not null default 'monthly',
  next_fee_on           date,
  labor_discount_pct    numeric(5,2) not null default 0,   -- for work not covered
  parts_discount_pct    numeric(5,2) not null default 0,
  diagnosis_amount      numeric(10,2),                      -- layer 4 override
  response_emergency_min int,                               -- e.g. 240 = 4 hours
  response_normal_min   int,
  response_low_min      int,
  billing_days          int,                                -- override of 7
  status                text not null default 'active' check (status in ('offered','active','ended')),
  accepted_by           uuid references profiles(id),
  accepted_at           timestamptz,
  created_at            timestamptz not null default now()
);
create table agreement_sites (
  agreement_id          uuid not null references agreements(id) on delete cascade,
  site_id               uuid not null references sites(id) on delete cascade,
  primary key (agreement_id, site_id)
);

-- ---------- Preventive maintenance plans -----------------------------
create table pm_plans (
  id                    uuid primary key default gen_random_uuid(),
  contractor_id         uuid not null references contractors(id) on delete cascade,
  customer_id           uuid not null references customers(id) on delete cascade,
  site_id               uuid not null references sites(id) on delete cascade,
  equipment_id          uuid references equipment(id),
  agreement_id          uuid references agreements(id),
  trade_id              smallint references trades(id),
  name                  text not null,             -- "Quarterly refrigeration PM"
  frequency_months      int not null check (frequency_months between 1 and 24),
  checklist             jsonb not null default '[]',  -- [{"item":"Clean condenser coil","photo":true,"reading":null,"required":true}]
  price                 numeric(10,2),             -- flat per visit; null = covered by agreement / T&M
  lead_days             int not null default 14,   -- create the work order this many days early
  next_due_on           date not null,
  active                boolean not null default true,
  created_at            timestamptz not null default now()
);
create table pm_plan_parts (
  pm_plan_id            uuid not null references pm_plans(id) on delete cascade,
  part_id               uuid not null references parts(id) on delete cascade,
  quantity              numeric(10,2) not null default 1,
  primary key (pm_plan_id, part_id)
);

-- ---------- Work orders (a job) --------------------------------------
create sequence work_order_number_seq start 1100;

create table work_orders (
  id                    uuid primary key default gen_random_uuid(),
  number                bigint not null unique default nextval('work_order_number_seq'),
  kind                  wo_kind not null default 'service',
  contractor_id         uuid not null references contractors(id),
  customer_id           uuid not null references customers(id),
  site_id               uuid not null references sites(id),
  equipment_id          uuid references equipment(id),
  trade_id              smallint references trades(id),
  issue_type_id         uuid references issue_types(id),
  repair_type_id        uuid references repair_types(id),
  agreement_id          uuid references agreements(id),
  pm_plan_id            uuid references pm_plans(id),
  parent_id             uuid references work_orders(id),   -- install job ← service job
  status                wo_status not null default 'created',
  priority              smallint not null default 2 check (priority between 1 and 3),
  after_hours           boolean not null default false,
  issue_description     text not null,
  work_summary          text,
  no_parts_used         boolean not null default false,
  flat_amount           numeric(10,2) not null default 0, -- flat PM price, when the plan has one
  checklist             jsonb not null default '[]',       -- PM tasks copied from the plan
  checklist_results     jsonb not null default '{}',       -- {"0":{"done":true,"reading":"38F","photo_id":"…"}}
  -- meet on site
  require_checkin       boolean not null default false,
  require_checkout      boolean not null default false,
  -- PO
  store_po_number       text,                     -- store's own number; else ours (PO + number)
  -- dates
  due_on                date,                     -- PM due date
  response_due_at       timestamptz,              -- from agreement
  response_met          boolean,
  created_by            uuid references profiles(id),
  created_at            timestamptz not null default now(),
  first_arrived_at      timestamptz,
  completed_at          timestamptz,
  cancelled_at          timestamptz,
  -- money (set only by recalc)
  labor_minutes_billed  int not null default 0,
  total_parts           numeric(10,2) not null default 0,
  total_labor           numeric(10,2) not null default 0,
  total_trip            numeric(10,2) not null default 0,
  total_cost            numeric(10,2) not null default 0,
  cost_labor            numeric(10,2) not null default 0,  -- what it cost the contractor
  cost_parts            numeric(10,2) not null default 0,
  -- warranty
  warranty_claim        boolean,                  -- this call is (not) warranty work
  warranty_decline_reason text,
  -- billing
  invoice_due_at        timestamptz,              -- completed_at + billing days
  invoice_ready         boolean not null default false,
  qbo_invoice_id        text,
  invoiced_at           timestamptz,
  updated_at            timestamptz not null default now()
);
create index on work_orders (contractor_id, status);
create index on work_orders (customer_id, status);
create index on work_orders (site_id, status);
create index on work_orders (equipment_id);
create index on work_orders (pm_plan_id) where pm_plan_id is not null;

-- Each trip to the site
create table visits (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  visit_no              int not null,
  technician_id         uuid not null references profiles(id),
  status                visit_status not null default 'assigned',
  outcome               visit_outcome,
  outcome_note          text,
  assigned_at           timestamptz not null default now(),
  received_at           timestamptz,              -- the phone confirmed it has the job
  eta_at                timestamptz,
  eta_alert_sent_at     timestamptz,
  started_at            timestamptz,
  arrived_at            timestamptz,
  departed_at           timestamptz,
  completed_at          timestamptz,
  -- check-in with a store person
  checkin_required      boolean not null default false,
  checkin_at            timestamptz,
  checkin_method        checkin_method,
  checkin_person        text,
  checkin_reason        text,
  checkin_verified      boolean,
  checkout_at           timestamptz,
  checkout_method       checkin_method,
  -- labor (set by recalc)
  labor_minutes_raw     int not null default 0,
  labor_minutes_billed  int not null default 0,
  labor_amount          numeric(10,2) not null default 0,
  unique (work_order_id, visit_no)
);
create index on visits (technician_id, status);

-- The check-in code. Readable by the store, NEVER by the technician.
create table visit_codes (
  visit_id              uuid primary key references visits(id) on delete cascade,
  code                  char(4) not null,
  created_at            timestamptz not null default now()
);

-- PO1100 (diagnosis) → A, B, C… each one an approved not-to-exceed amount
create table po_lines (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  seq                   int not null,             -- 0 = base, 1 = A, 2 = B…
  kind                  po_line_kind not null,
  amount                numeric(10,2) not null check (amount >= 0),
  description           text not null,
  breakdown             jsonb,                    -- simple repair quote: {"parts":[…],"labor_hours":2,"notes":…}
  store_po_number       text,                     -- override for stores needing separate numbers
  status                approval_status not null default 'pending',
  requested_by          uuid references profiles(id),
  requested_at          timestamptz not null default now(),
  routed_step           int,                      -- which chain step it is waiting on
  routed_at             timestamptz,
  decided_by            uuid references profiles(id),
  decided_at            timestamptz,
  decided_limit         numeric(10,2),            -- the decider's limit at that moment
  decline_reason        text,
  unique (work_order_id, seq)
);

create table photos (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  visit_id              uuid references visits(id) on delete cascade,
  equipment_id          uuid references equipment(id),
  part_id               uuid references parts(id),
  po_line_id            uuid references po_lines(id),
  kind                  photo_kind not null,
  storage_path          text not null,
  taken_at              timestamptz not null,
  lat                   double precision,
  lon                   double precision,
  ai_result             jsonb,
  uploaded_by           uuid not null references profiles(id),
  uploaded_at           timestamptz not null default now()
);
create index on photos (work_order_id, kind);

create table parts_used (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  visit_id              uuid references visits(id) on delete set null,
  part_id               uuid not null references parts(id),
  quantity              numeric(10,2) not null check (quantity > 0),
  source                part_source not null default 'truck',
  unit_price            numeric(10,2) not null,   -- billed (after agreement coverage/discount)
  unit_cost             numeric(10,2),            -- contractor's cost, for job costing
  covered               boolean not null default false,
  total_price           numeric(10,2) generated always as (round(quantity * unit_price, 2)) stored,
  added_by              uuid references profiles(id),
  added_at              timestamptz not null default now(),
  unique (work_order_id, part_id, source)
);

create table parts_orders (                        -- waiting for parts
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  visit_id              uuid references visits(id),
  part_id               uuid references parts(id),
  description           text not null,
  quantity              numeric(10,2) not null default 1,
  supplier              text,
  expected_on           date,
  status                parts_order_status not null default 'needed',
  created_by            uuid references profiles(id),
  created_at            timestamptz not null default now(),
  received_at           timestamptz
);

create table gps_logs (
  id                    bigint generated always as identity primary key,
  technician_id         uuid not null references profiles(id),
  work_order_id         uuid references work_orders(id) on delete cascade,
  visit_id              uuid references visits(id) on delete cascade,
  lat                   double precision not null,
  lon                   double precision not null,
  accuracy_m            real,
  event                 gps_event not null default 'ping',
  recorded_at           timestamptz not null,
  received_at           timestamptz not null default now()
);
create index on gps_logs (technician_id, recorded_at desc);
create index on gps_logs (visit_id, recorded_at);

create table guardrail_flags (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  flag                  flag_type not null,
  description           text not null,
  blocking              boolean not null default true,
  visible_to_customer   boolean not null default false,
  triggered_at          timestamptz not null default now(),
  resolved_at           timestamptz,
  resolved_by           uuid references profiles(id),
  resolution_note       text
);
create unique index guardrail_one_open on guardrail_flags (work_order_id, flag) where resolved_at is null;

create table time_overrides (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  visit_id              uuid not null references visits(id) on delete cascade,
  field                 text not null check (field in ('started_at','arrived_at','departed_at','completed_at')),
  old_value             timestamptz,
  new_value             timestamptz not null,
  reason                text not null check (length(reason) >= 10),
  overridden_by         uuid not null references profiles(id),
  overridden_at         timestamptz not null default now()
);

create table warranties (
  id                    uuid primary key default gen_random_uuid(),
  work_order_id         uuid not null references work_orders(id) on delete cascade,
  equipment_id          uuid not null references equipment(id) on delete cascade,
  part_id               uuid references parts(id),
  kind                  text not null check (kind in ('labor','parts')),
  starts_on             date not null,
  ends_on               date not null,
  description           text not null,
  created_by            uuid references profiles(id),
  created_at            timestamptz not null default now()
);
create index on warranties (equipment_id, ends_on);

create table notifications (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references profiles(id) on delete cascade,
  work_order_id         uuid references work_orders(id) on delete cascade,
  type                  notify_type not null,
  message               text not null,
  dedupe_key            text,
  created_at            timestamptz not null default now(),
  sent_at               timestamptz,
  read_at               timestamptz
);
create index on notifications (user_id, read_at);
create unique index notifications_dedupe on notifications (user_id, dedupe_key) where dedupe_key is not null;

-- ---------- Timecards ------------------------------------------------
create table time_entries (
  id                    uuid primary key default gen_random_uuid(),   -- created on the phone
  profile_id            uuid not null references profiles(id) on delete cascade,
  kind                  time_kind not null default 'shift',
  start_at              timestamptz not null,
  end_at                timestamptz check (end_at is null or end_at > start_at),
  note                  text,
  created_at            timestamptz not null default now()
);
create index on time_entries (profile_id, start_at);

create table timesheet_approvals (
  profile_id            uuid not null references profiles(id) on delete cascade,
  week_start            date not null,            -- Monday
  approved_by           uuid not null references profiles(id),
  approved_at           timestamptz not null default now(),
  exported_at           timestamptz,
  primary key (profile_id, week_start)
);

-- ---------- Platform fees & wholesaler commission --------------------
create table platform_fees (                        -- one row per side per job
  id                    uuid primary key default gen_random_uuid(),
  org_kind              org_kind not null check (org_kind in ('contractor','customer')),
  org_id                uuid not null,
  work_order_id         uuid not null references work_orders(id),
  technician_id         uuid references profiles(id),
  billing_month         date not null,
  amount                numeric(10,2) not null,   -- before monthly caps
  waived                boolean not null default false,
  created_at            timestamptz not null default now(),
  unique (org_kind, org_id, work_order_id)
);

create table monthly_statements (
  id                    uuid primary key default gen_random_uuid(),
  org_kind              org_kind not null,
  org_id                uuid not null,
  billing_month         date not null,
  usage_fees            numeric(10,2) not null default 0,
  cap_applied           numeric(10,2),
  subscription_fees     numeric(10,2) not null default 0,
  total                 numeric(10,2) not null default 0,
  detail                jsonb not null default '{}',
  status                text not null default 'draft' check (status in ('draft','sent','paid','void')),
  paid_at               timestamptz,
  created_at            timestamptz not null default now(),
  unique (org_kind, org_id, billing_month)
);

create table commissions (
  id                    uuid primary key default gen_random_uuid(),
  wholesaler_id         uuid not null references wholesalers(id),
  statement_id          uuid not null references monthly_statements(id),
  amount                numeric(10,2) not null,
  status                text not null default 'pending' check (status in ('pending','paid','void')),
  paid_at               timestamptz,
  stripe_transfer_id    text,
  unique (statement_id)
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

-- Lock everything until 0004 grants access deliberately.
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;
