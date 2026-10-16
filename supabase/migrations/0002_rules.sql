-- =====================================================================
-- ServicePro — business rules
-- Every rule lives in the database so the phone app, the web portals,
-- and any future integration all get the same enforcement.
--
-- Pattern: apps READ tables directly (filtered by row-level security)
-- and WRITE through the functions below (Supabase RPC). Functions run
-- as owner (security definer) and check the caller's permissions
-- themselves.
-- =====================================================================

-- ---------- Caller helpers -------------------------------------------
create or replace function me() returns profiles
language sql stable security definer set search_path = public as $$
  select * from profiles where id = auth.uid() and active
$$;

create or replace function is_contractor_staff(p_contractor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active
                 and contractor_id = p_contractor)
$$;

create or replace function is_contractor_office(p_contractor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active
                 and contractor_id = p_contractor and role in ('contractor_admin','dispatcher'))
$$;

create or replace function is_customer_user(p_customer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active
                 and customer_id = p_customer)
$$;

create or replace function is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and role = 'platform_admin')
$$;

create or replace function has_agreement(p_contractor uuid, p_customer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from service_agreements where contractor_id = p_contractor and customer_id = p_customer)
$$;

create or replace function can_see_work_order(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from work_orders w
    join profiles p on p.id = auth.uid() and p.active
    where w.id = p_wo and (
         p.role = 'platform_admin'
      or (p.role in ('contractor_admin','dispatcher') and w.contractor_id = p.contractor_id)
      or (p.role = 'technician' and w.technician_id = p.id)
      or (p.role in ('customer_admin','customer_user') and w.customer_id = p.customer_id)))
$$;

-- Lets functions change protected columns; scoped to the current transaction.
create or replace function _allow_internal(p_override boolean default false) returns void
language sql set search_path = public as $$
  select set_config('app.internal', 'on', true),
         set_config('app.override', case when p_override then 'on' else 'off' end, true);
$$;

create or replace function _end_internal() returns void
language sql set search_path = public as $$
  select set_config('app.internal', 'off', true), set_config('app.override', 'off', true);
$$;

-- 1.00 -> "1", 2.50 -> "2.5"
create or replace function _qty(n numeric) returns text language sql immutable set search_path = public as $$
  select trim(trailing '.' from trim(trailing '0' from n::text))
$$;

-- Distance in feet between two points (haversine)
create or replace function distance_ft(lat1 double precision, lon1 double precision,
                                       lat2 double precision, lon2 double precision)
returns double precision language sql immutable set search_path = public as $$
  select 20902231 * 2 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

-- Device timestamps are trusted only within sane bounds
create or replace function _device_time(p_at timestamptz) returns timestamptz
language plpgsql stable set search_path = public as $$
begin
  if p_at is null then return now(); end if;
  if p_at > now() + interval '5 minutes' then
    raise exception 'Device clock is ahead of server time (%). Check phone date/time settings.', p_at
      using errcode = 'P0001';
  end if;
  if p_at < now() - interval '7 days' then
    raise exception 'Timestamp % is more than 7 days old; use a time override instead.', p_at;
  end if;
  return p_at;
end $$;

-- ---------- Notifications --------------------------------------------
create or replace function _notify(p_user uuid, p_wo uuid, p_type notify_type, p_msg text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, work_order_id, type, message) values (p_user, p_wo, p_type, p_msg)
$$;

create or replace function _notify_customer(p_wo uuid, p_type notify_type, p_msg text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, work_order_id, type, message)
  select p.id, w.id, p_type, p_msg from work_orders w
  join profiles p on p.customer_id = w.customer_id and p.active
  where w.id = p_wo
$$;

create or replace function _notify_office(p_wo uuid, p_type notify_type, p_msg text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, work_order_id, type, message)
  select p.id, w.id, p_type, p_msg from work_orders w
  join profiles p on p.contractor_id = w.contractor_id and p.active
                 and p.role in ('contractor_admin','dispatcher')
  where w.id = p_wo
$$;

-- ---------- Work order protection trigger -----------------------------
create or replace function _wo_transition_ok(o wo_status, n wo_status) returns boolean
language sql immutable set search_path = public as $$
  select (o, n) in (
    ('created','assigned'), ('created','cancelled'),
    ('assigned','assigned'), ('assigned','created'), ('assigned','en_route'), ('assigned','cancelled'),
    ('en_route','assigned'), ('en_route','on_site'), ('en_route','cancelled'),
    ('on_site','awaiting_approval'), ('on_site','completed'),
    ('awaiting_approval','on_site'), ('awaiting_approval','completed'),
    ('completed','invoiced'))
$$;

create or replace function _wo_guard() returns trigger
language plpgsql set search_path = public as $$
declare
  internal boolean := coalesce(current_setting('app.internal', true), 'off') = 'on';
  override boolean := coalesce(current_setting('app.override', true), 'off') = 'on';
begin
  new.updated_at := now();

  if old.status = 'invoiced' and not override then
    raise exception 'Work order % is invoiced and locked.', old.number;
  end if;

  if not internal then
    -- Direct edits (allowed columns only, via grants) — make sure nothing else moved.
    if (new.status, new.contractor_id, new.customer_id, new.site_id, new.technician_id,
        new.repair_type_id, new.equipment_id, new.no_parts_used, new.po_cap,
        new.assigned_at, new.started_at, new.arrived_at, new.departed_at, new.completed_at, new.cancelled_at,
        new.labor_minutes_billed, new.total_parts, new.total_labor, new.total_trip, new.total_cost,
        new.invoice_ready, new.qbo_invoice_id, new.exported_at, new.eta_at)
       is distinct from
       (old.status, old.contractor_id, old.customer_id, old.site_id, old.technician_id,
        old.repair_type_id, old.equipment_id, old.no_parts_used, old.po_cap,
        old.assigned_at, old.started_at, old.arrived_at, old.departed_at, old.completed_at, old.cancelled_at,
        old.labor_minutes_billed, old.total_parts, old.total_labor, old.total_trip, old.total_cost,
        old.invoice_ready, old.qbo_invoice_id, old.exported_at, old.eta_at) then
      raise exception 'That change must go through the app actions, not a direct edit.';
    end if;
    if old.status in ('completed') and new.issue_description is distinct from old.issue_description then
      raise exception 'Completed work orders cannot be re-described.';
    end if;
  end if;

  -- Lifecycle timestamps are write-once except through a logged override.
  if not override then
    if (old.started_at   is not null and new.started_at   is distinct from old.started_at) or
       (old.arrived_at   is not null and new.arrived_at   is distinct from old.arrived_at) or
       (old.departed_at  is not null and new.departed_at  is distinct from old.departed_at) or
       (old.completed_at is not null and new.completed_at is distinct from old.completed_at) then
      raise exception 'Arrival/departure/completion times cannot be edited. Use a time override (logged).';
    end if;
  end if;

  if new.status is distinct from old.status and not _wo_transition_ok(old.status, new.status) then
    raise exception 'Cannot move work order from % to %.', old.status, new.status;
  end if;

  return new;
end $$;

create trigger work_orders_guard before update on work_orders
for each row execute function _wo_guard();

-- ---------- Audit trail ----------------------------------------------
create or replace function _audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (table_name, row_id, action, actor, old_data, new_data)
  values (tg_table_name,
          coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id', null)::uuid,
          tg_op, auth.uid(),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return null;
end $$;

create trigger audit_work_orders     after insert or update or delete on work_orders     for each row execute function _audit();
create trigger audit_parts_used      after insert or update or delete on parts_used      for each row execute function _audit();
create trigger audit_approvals       after insert or update or delete on approvals       for each row execute function _audit();
create trigger audit_guardrail_flags after insert or update or delete on guardrail_flags for each row execute function _audit();
create trigger audit_equipment       after insert or update or delete on equipment       for each row execute function _audit();
create trigger audit_time_overrides  after insert or update or delete on time_overrides  for each row execute function _audit();
create trigger audit_photos          after insert or update or delete on photos          for each row execute function _audit();

-- ---------- Cost engine ----------------------------------------------
create or replace function part_price(p_part uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(pt.unit_price, round(coalesce(pt.unit_cost, 0) * (1 + c.parts_markup_pct / 100), 2))
  from parts pt join contractors c on c.id = pt.contractor_id where pt.id = p_part
$$;

-- Pure calculation: what would this work order cost if labor ended at p_end?
create or replace function compute_costs(p_wo uuid, p_end timestamptz default null)
returns table (raw_labor_minutes int, labor_minutes_billed int, parts numeric, labor numeric, trip numeric, total numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  w work_orders; c contractors; v_end timestamptz; v_raw int := 0; v_billed int := 0; v_parts numeric;
begin
  select * into w from work_orders where id = p_wo;
  select * into c from contractors where id = w.contractor_id;
  v_end := coalesce(p_end, w.completed_at, now());

  if w.arrived_at is not null then
    v_raw := greatest(0, ceil(extract(epoch from (v_end - w.arrived_at)) / 60))::int;
    if c.bill_travel_time and w.started_at is not null then
      v_raw := v_raw + greatest(0, ceil(extract(epoch from (w.arrived_at - w.started_at)) / 60))::int;
    end if;
    v_billed := greatest(c.min_labor_minutes,
                         (ceil(v_raw::numeric / c.labor_increment_min) * c.labor_increment_min)::int);
  end if;

  select coalesce(sum(total_price), 0) into v_parts from parts_used where work_order_id = p_wo;

  raw_labor_minutes    := v_raw;
  labor_minutes_billed := v_billed;
  parts                := v_parts;
  labor                := round(v_billed::numeric / 60 * c.labor_rate, 2);
  trip                 := case when w.arrived_at is not null then c.trip_charge else 0 end;
  total                := parts + labor + trip;
  return next;
end $$;

create or replace function effective_cap(p_wo uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select w.po_cap + coalesce((select sum(requested_amount) from approvals
                              where work_order_id = w.id and status = 'approved'), 0)
  from work_orders w where w.id = p_wo
$$;

create or replace function _raise_flag(p_wo uuid, p_flag flag_type, p_desc text, p_blocking boolean default true)
returns void language sql security definer set search_path = public as $$
  insert into guardrail_flags (work_order_id, flag, description, blocking)
  values (p_wo, p_flag, p_desc, p_blocking)
  on conflict (work_order_id, flag) where resolved_at is null
  do update set description = excluded.description
$$;

-- Writes current costs onto the work order and handles PO warnings.
create or replace function recalc_work_order(p_wo uuid) returns work_orders
language plpgsql security definer set search_path = public as $$
declare w work_orders; k record; v_cap numeric; v_warn numeric;
begin
  select * into k from compute_costs(p_wo);
  perform _allow_internal();
  update work_orders set labor_minutes_billed = k.labor_minutes_billed, total_parts = k.parts,
         total_labor = k.labor, total_trip = k.trip, total_cost = k.total
   where id = p_wo returning * into w;
  perform _end_internal();

  if w.po_cap is not null and w.status in ('on_site','awaiting_approval') then
    v_cap  := effective_cap(p_wo);
    select po_warn_pct into v_warn from contractors where id = w.contractor_id;
    if w.total_cost >= v_cap * v_warn / 100
       and not exists (select 1 from guardrail_flags where work_order_id = p_wo and flag = 'po_near_cap' and resolved_at is null) then
      perform _raise_flag(p_wo, 'po_near_cap',
        format('Cost $%s is at %s%% of approved $%s.', w.total_cost, round(w.total_cost / v_cap * 100), v_cap), false);
      perform _notify_customer(p_wo, 'guardrail_flag',
        format('WO #%s is at $%s of your $%s cap.', w.number, w.total_cost, v_cap));
      perform _notify_office(p_wo, 'guardrail_flag',
        format('WO #%s is approaching its PO cap ($%s of $%s).', w.number, w.total_cost, v_cap));
    end if;
  end if;
  return w;
end $$;

-- ---------- Work order lifecycle: office & customer -------------------
create or replace function create_work_order(
  p_site uuid, p_issue text, p_contractor uuid default null, p_equipment uuid default null,
  p_priority smallint default 2, p_po_number text default null, p_po_cap numeric default null,
  p_id uuid default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; v_contractor uuid; w work_orders;
begin
  if m.id is null then raise exception 'Not signed in.'; end if;
  select * into s from sites where id = p_site;
  if s.id is null then raise exception 'Unknown site.'; end if;
  if coalesce(trim(p_issue), '') = '' then raise exception 'Describe the problem.'; end if;

  if m.role in ('customer_admin','customer_user') then
    if s.customer_id <> m.customer_id then raise exception 'That site is not yours.'; end if;
    v_contractor := p_contractor;
    if v_contractor is null then
      select contractor_id into v_contractor from service_agreements where customer_id = m.customer_id
      order by created_at limit 1;
    end if;
  elsif m.role in ('contractor_admin','dispatcher') then
    v_contractor := m.contractor_id;
  else
    raise exception 'Your role cannot create work orders.';
  end if;

  if not has_agreement(v_contractor, s.customer_id) then
    raise exception 'No service agreement between that contractor and customer.';
  end if;
  if p_equipment is not null and not exists (select 1 from equipment where id = p_equipment and site_id = p_site) then
    raise exception 'That equipment is not at this site.';
  end if;

  insert into work_orders (id, contractor_id, customer_id, site_id, equipment_id, priority,
                           issue_description, po_number, po_cap, created_by)
  values (coalesce(p_id, gen_random_uuid()), v_contractor, s.customer_id, p_site, p_equipment, p_priority,
          trim(p_issue), p_po_number,
          coalesce(p_po_cap, (select default_po_cap from service_agreements
                               where contractor_id = v_contractor and customer_id = s.customer_id)),
          m.id)
  returning * into w;

  if m.customer_id is not null then
    perform _notify_office(w.id, 'eta_update', format('New service call #%s at %s: %s', w.number, s.name, w.issue_description));
  end if;
  return w;
end $$;

create or replace function assign_work_order(p_wo uuid, p_tech uuid,
  p_scheduled_for timestamptz default null, p_estimated_minutes int default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders; t profiles;
begin
  select * into w from work_orders where id = p_wo for update;
  if not is_contractor_office(w.contractor_id) then raise exception 'Only the contractor office can assign.'; end if;
  select * into t from profiles where id = p_tech and role = 'technician' and active and contractor_id = w.contractor_id;
  if t.id is null then raise exception 'That person is not an active technician of this contractor.'; end if;
  if w.status not in ('created','assigned','en_route') then
    raise exception 'Cannot reassign once the technician is on site.';
  end if;

  perform _allow_internal(true);  -- override: clearing started_at on reassignment
  update work_orders set technician_id = p_tech, status = 'assigned', assigned_at = now(),
         started_at = null, -- a reassigned job restarts the drive
         scheduled_for = coalesce(p_scheduled_for, scheduled_for),
         estimated_minutes = coalesce(p_estimated_minutes, estimated_minutes)
   where id = p_wo returning * into w;
  perform _end_internal();

  perform _notify(p_tech, p_wo, 'eta_update', format('New job #%s assigned to you.', w.number));
  perform _notify_customer(p_wo, 'eta_update', format('%s has been assigned to call #%s.', t.full_name, w.number));
  return w;
end $$;

create or replace function set_po_cap(p_wo uuid, p_cap numeric, p_po_number text default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if not (is_customer_user(w.customer_id) or is_contractor_office(w.contractor_id)) then
    raise exception 'Not allowed.';
  end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'Work order is closed.'; end if;
  if p_cap is not null and p_cap < w.total_cost then
    raise exception 'Cap $% is below the current cost $%.', p_cap, w.total_cost;
  end if;
  perform _allow_internal();
  update work_orders set po_cap = p_cap, po_number = coalesce(p_po_number, po_number)
   where id = p_wo returning * into w;
  perform _end_internal();
  return w;
end $$;

create or replace function cancel_work_order(p_wo uuid, p_reason text)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if is_customer_user(w.customer_id) then
    if w.status not in ('created','assigned') then
      raise exception 'The technician is already on the way; call the contractor to cancel.';
    end if;
  elsif not is_contractor_office(w.contractor_id) then
    raise exception 'Not allowed.';
  end if;
  perform _allow_internal();
  update work_orders set status = 'cancelled', cancelled_at = now(),
         work_summary = coalesce(work_summary || E'\n', '') || 'Cancelled: ' || p_reason
   where id = p_wo returning * into w;
  perform _end_internal();
  return w;
end $$;

-- ---------- Technician actions ---------------------------------------
create or replace function _my_job(p_wo uuid) returns work_orders
language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or w.technician_id is distinct from auth.uid() then
    raise exception 'This job is not assigned to you.';
  end if;
  return w;
end $$;

create or replace function tech_start(p_wo uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo); v_at timestamptz := _device_time(p_at);
begin
  if w.status = 'en_route' then return w; end if;  -- duplicate sync, ignore
  if w.status <> 'assigned' then raise exception 'Job is %, cannot start.', w.status; end if;
  perform _allow_internal();
  update work_orders set status = 'en_route', started_at = greatest(v_at, assigned_at)
   where id = p_wo returning * into w;
  perform _end_internal();
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, lat, lon, event, recorded_at)
    values (auth.uid(), p_wo, p_lat, p_lon, 'en_route', v_at);
  end if;
  perform _notify_customer(p_wo, 'eta_update', format('Technician is on the way for call #%s.', w.number));
  return w;
end $$;

-- The phone computes drive time (maps) and reports the expected arrival time.
-- Stores see the ETA, never the tech's live position. They are notified the
-- first time, and again only when the ETA slips or improves by 15+ minutes.
create or replace function tech_update_eta(p_wo uuid, p_eta_at timestamptz)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo); v_old timestamptz := w.eta_at;
begin
  if w.status not in ('assigned','en_route') then return w; end if;  -- late sync after arrival: ignore
  if p_eta_at < now() - interval '5 minutes' or p_eta_at > now() + interval '24 hours' then
    raise exception 'ETA % is not plausible.', p_eta_at;
  end if;
  perform _allow_internal();
  update work_orders set eta_at = p_eta_at where id = p_wo returning * into w;
  perform _end_internal();
  if v_old is null or abs(extract(epoch from (p_eta_at - v_old))) >= 15 * 60 then
    perform _notify_customer(p_wo, 'eta_update',
      format('Call #%s: technician expected at %s.', w.number, to_char(p_eta_at at time zone 'America/Chicago', 'HH12:MI AM')));
  end if;
  return w;
end $$;

-- p_source: 'geofence' (automatic) or 'manual' (tech tapped Arrived)
create or replace function tech_arrive(p_wo uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null, p_source text default 'geofence')
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo); v_at timestamptz := _device_time(p_at); s sites; v_dist double precision;
begin
  if w.status in ('on_site','awaiting_approval') then return w; end if;
  if w.status <> 'en_route' then raise exception 'Tap Start before arriving.'; end if;
  select * into s from sites where id = w.site_id;

  perform _allow_internal();
  update work_orders set status = 'on_site', arrived_at = greatest(v_at, started_at)
   where id = p_wo returning * into w;
  perform _end_internal();

  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, lat, lon, event, recorded_at)
    values (auth.uid(), p_wo, p_lat, p_lon, case when p_source = 'geofence' then 'geofence_enter'::gps_event else 'arrived'::gps_event end, v_at);
  end if;

  -- Arrival far from the store, or with no location at all, gets reviewed (never blocks the tech).
  if p_lat is null then
    perform _raise_flag(p_wo, 'gps_mismatch', 'Arrival recorded with no GPS location.', false);
  elsif s.lat is not null then
    v_dist := distance_ft(p_lat, p_lon, s.lat, s.lon);
    if v_dist > s.geofence_radius_ft * 2 then
      perform _raise_flag(p_wo, 'gps_mismatch',
        format('Arrival recorded %s ft from the site (geofence %s ft).', round(v_dist::numeric), s.geofence_radius_ft), true);
    end if;
  end if;

  perform _notify_customer(p_wo, 'arrival', format('Technician arrived for call #%s at %s.', w.number, to_char(w.arrived_at, 'HH12:MI AM')));
  return w;
end $$;

create or replace function tech_depart(p_wo uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo); v_at timestamptz := _device_time(p_at);
begin
  if w.departed_at is not null then return w; end if;
  if w.arrived_at is null then raise exception 'Not on site.'; end if;
  perform _allow_internal();
  update work_orders set departed_at = greatest(v_at, arrived_at) where id = p_wo returning * into w;
  perform _end_internal();
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, lat, lon, event, recorded_at)
    values (auth.uid(), p_wo, p_lat, p_lon, 'geofence_exit', v_at);
  end if;
  return w;
end $$;

-- Batch upload of location pings (phone queues them while offline)
-- p_points: [{"lat":..,"lon":..,"accuracy_m":..,"at":"2026-10-15T14:00:00Z","work_order_id":null}, ...]
create or replace function log_gps(p_points jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); n int;
begin
  if m.role is distinct from 'technician' then raise exception 'Technicians only.'; end if;
  insert into gps_logs (technician_id, work_order_id, lat, lon, accuracy_m, event, recorded_at)
  select m.id,
         case when (pt->>'work_order_id') is not null
                and exists (select 1 from work_orders where id = (pt->>'work_order_id')::uuid and technician_id = m.id)
              then (pt->>'work_order_id')::uuid end,
         (pt->>'lat')::float8, (pt->>'lon')::float8, (pt->>'accuracy_m')::real, 'ping',
         least((pt->>'at')::timestamptz, now())
  from jsonb_array_elements(p_points) pt;
  get diagnostics n = row_count;
  return n;
end $$;

-- Confirm (or create) the equipment record from the nameplate photo.
create or replace function confirm_equipment(p_wo uuid, p_type equipment_type, p_manufacturer text,
  p_model text, p_serial text, p_location text default null, p_equipment uuid default null,
  p_refrigerant text default null)
returns equipment language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo); e equipment;
begin
  if w.status not in ('on_site','awaiting_approval') then raise exception 'Arrive on site first.'; end if;
  if coalesce(trim(p_model), '') = '' or coalesce(trim(p_serial), '') = '' then
    raise exception 'Model and serial are both required. If the plate is unreadable, enter UNREADABLE and photograph it.';
  end if;

  -- Reuse a known unit: explicit id, else same make + serial at this site.
  if p_equipment is not null then
    select * into e from equipment where id = p_equipment and site_id = w.site_id;
  end if;
  if e.id is null then
    select * into e from equipment where site_id = w.site_id
      and lower(manufacturer) = lower(trim(p_manufacturer)) and lower(serial) = lower(trim(p_serial));
  end if;
  if e.id is null and w.equipment_id is not null then
    select * into e from equipment where id = w.equipment_id and identity_confirmed = false;
  end if;

  if e.id is null then
    insert into equipment (customer_id, site_id, type, manufacturer, model, serial, refrigerant,
                           location_description, identity_confirmed, confirmed_by, confirmed_at)
    values (w.customer_id, w.site_id, p_type, trim(p_manufacturer), trim(p_model), trim(p_serial), p_refrigerant,
            p_location, true, auth.uid(), now())
    returning * into e;
  else
    update equipment set type = p_type, manufacturer = trim(p_manufacturer), model = trim(p_model),
           serial = trim(p_serial), refrigerant = coalesce(p_refrigerant, refrigerant),
           location_description = coalesce(p_location, location_description),
           identity_confirmed = true, confirmed_by = auth.uid(), confirmed_at = now()
     where id = e.id returning * into e;
  end if;

  perform _allow_internal();
  update work_orders set equipment_id = e.id where id = p_wo;
  perform _end_internal();
  update photos set equipment_id = e.id where work_order_id = p_wo and kind in ('equipment','nameplate') and equipment_id is null;
  return e;
end $$;

create or replace function _apply_summary(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; rt repair_types; e equipment; v_parts text; v text;
begin
  select * into w from work_orders where id = p_wo;
  select * into rt from repair_types where id = w.repair_type_id;
  select * into e from equipment where id = w.equipment_id;
  select string_agg(format('%s x%s', pt.name, _qty(pu.quantity)), ', ' order by pt.name)
    into v_parts from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = p_wo;
  v := coalesce(rt.summary_template, 'Service performed.');
  v := replace(v, '{equipment}', coalesce(nullif(concat_ws(' ', e.manufacturer, e.model), ''), 'unit'));
  v := replace(v, '{location}',  coalesce(e.location_description, 'on site'));
  v := v || case when v_parts is not null then ' Parts: ' || v_parts || '.'
                 when w.no_parts_used then ' No parts used.' else '' end;
  perform _allow_internal();
  update work_orders set work_summary = v where id = p_wo;
  perform _end_internal();
end $$;

create or replace function _upsert_part(p_wo uuid, p_part uuid, p_qty numeric, p_source part_source) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_qty <= 0 then
    delete from parts_used where work_order_id = p_wo and part_id = p_part and source = p_source;
  else
    insert into parts_used (work_order_id, part_id, quantity, source, unit_price, added_by)
    values (p_wo, p_part, p_qty, p_source, part_price(p_part), auth.uid())
    on conflict (work_order_id, part_id, source) do update set quantity = excluded.quantity;
  end if;
end $$;

-- Pick the repair type; optionally pre-fills its parts kit (tech unchecks what wasn't used).
create or replace function set_repair_type(p_wo uuid, p_repair_type uuid, p_apply_kit boolean default true)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo); rt repair_types; k record;
begin
  if w.status not in ('on_site','awaiting_approval') then raise exception 'Arrive on site first.'; end if;
  select * into rt from repair_types where id = p_repair_type and contractor_id = w.contractor_id and active;
  if rt.id is null then raise exception 'Unknown repair type.'; end if;

  perform _allow_internal();
  update work_orders set repair_type_id = rt.id where id = p_wo;
  perform _end_internal();

  if p_apply_kit then
    for k in select part_id, quantity from repair_type_parts where repair_type_id = rt.id loop
      if not exists (select 1 from parts_used where work_order_id = p_wo and part_id = k.part_id) then
        perform _upsert_part(p_wo, k.part_id, k.quantity, 'truck');
      end if;
    end loop;
    if found then
      perform _allow_internal();
      update work_orders set no_parts_used = false where id = p_wo;
      perform _end_internal();
    end if;
  end if;

  perform _apply_summary(p_wo);
  return recalc_work_order(p_wo);
end $$;

-- Set quantity of a part (0 removes it).
create or replace function set_part_used(p_wo uuid, p_part uuid, p_qty numeric, p_source part_source default 'truck')
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo);
begin
  if w.status not in ('on_site','awaiting_approval') then raise exception 'Arrive on site first.'; end if;
  if not exists (select 1 from parts where id = p_part and contractor_id = w.contractor_id) then
    raise exception 'Unknown part.';
  end if;
  perform _upsert_part(p_wo, p_part, p_qty, p_source);
  if p_qty > 0 then
    perform _allow_internal();
    update work_orders set no_parts_used = false where id = p_wo;
    perform _end_internal();
  end if;
  perform _apply_summary(p_wo);
  return recalc_work_order(p_wo);
end $$;

create or replace function set_no_parts_used(p_wo uuid, p_value boolean)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo);
begin
  if p_value and exists (select 1 from parts_used where work_order_id = p_wo) then
    raise exception 'Remove the selected parts first, or keep them.';
  end if;
  perform _allow_internal();
  update work_orders set no_parts_used = p_value where id = p_wo;
  perform _end_internal();
  perform _apply_summary(p_wo);
  return recalc_work_order(p_wo);
end $$;

-- What still stands between this job and Complete? Empty result = ready.
-- The phone shows these as the checklist on the job screen.
create or replace function completion_check(p_wo uuid, p_end timestamptz default null)
returns table (item text, message text)
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; e equipment; rt repair_types; k record; v_cap numeric;
begin
  if not can_see_work_order(p_wo) then raise exception 'Not allowed.'; end if;
  select * into w from work_orders where id = p_wo;
  select * into e from equipment where id = w.equipment_id;
  select * into rt from repair_types where id = w.repair_type_id;

  if w.status not in ('on_site','awaiting_approval') then
    item := 'status'; message := 'Job must be on site to complete.'; return next;
  end if;
  if e.id is null or not e.identity_confirmed or coalesce(e.model,'') = '' or coalesce(e.serial,'') = '' then
    item := 'equipment'; message := 'Confirm the equipment model and serial.'; return next;
  end if;
  if not exists (select 1 from photos where work_order_id = p_wo and kind in ('equipment','nameplate')) then
    item := 'equipment_photo'; message := 'Take a photo of the equipment nameplate.'; return next;
  end if;
  if not exists (select 1 from photos where work_order_id = p_wo and kind = 'before') then
    item := 'before_photo'; message := 'Take a BEFORE photo.'; return next;
  end if;
  if not exists (select 1 from photos where work_order_id = p_wo and kind = 'after') then
    item := 'after_photo'; message := 'Take an AFTER photo.'; return next;
  end if;
  if rt.id is null then
    item := 'repair_type'; message := 'Select the repair performed.'; return next;
  end if;
  if not exists (select 1 from parts_used where work_order_id = p_wo) and not w.no_parts_used then
    item := 'parts'; message := 'Select parts used, or tap "No parts used".'; return next;
  end if;
  if exists (select 1 from approvals where work_order_id = p_wo and status = 'pending') then
    item := 'approval_pending'; message := 'Waiting for the customer to approve the added cost.'; return next;
  end if;
  if w.po_cap is not null then
    select * into k from compute_costs(p_wo, coalesce(p_end, now()));
    v_cap := effective_cap(p_wo);
    if k.total > v_cap then
      item := 'po_cap';
      message := format('Cost $%s is over the approved $%s. Request approval for $%s more.', k.total, v_cap, k.total - v_cap);
      return next;
    end if;
  end if;
end $$;

create or replace function request_approval(p_wo uuid, p_amount numeric, p_reason text)
returns approvals language plpgsql security definer set search_path = public as $$
declare w work_orders; a approvals;
begin
  select * into w from work_orders where id = p_wo for update;
  if not (w.technician_id = auth.uid() or is_contractor_office(w.contractor_id)) then raise exception 'Not allowed.'; end if;
  if w.status not in ('on_site','awaiting_approval') then raise exception 'Only while on site.'; end if;
  if w.po_cap is null then raise exception 'This call has no PO cap; no approval needed.'; end if;
  if exists (select 1 from approvals where work_order_id = p_wo and status = 'pending') then
    raise exception 'An approval request is already waiting.';
  end if;
  insert into approvals (work_order_id, requested_by, requested_amount, reason)
  values (p_wo, auth.uid(), p_amount, p_reason) returning * into a;

  perform _allow_internal();
  update work_orders set status = 'awaiting_approval' where id = p_wo and status = 'on_site';
  perform _end_internal();
  perform _raise_flag(p_wo, 'po_exceeded', format('Requested $%s over cap: %s', p_amount, p_reason), false);
  perform _notify_customer(p_wo, 'approval_request',
    format('Call #%s needs approval for $%s more: %s', w.number, p_amount, p_reason));
  return a;
end $$;

create or replace function decide_approval(p_approval uuid, p_approve boolean)
returns approvals language plpgsql security definer set search_path = public as $$
declare a approvals; w work_orders;
begin
  select * into a from approvals where id = p_approval for update;
  select * into w from work_orders where id = a.work_order_id for update;
  if not exists (select 1 from profiles where id = auth.uid() and active and customer_id = w.customer_id
                 and role in ('customer_admin','customer_user')) then
    raise exception 'Only the customer can approve added cost.';
  end if;
  if a.status <> 'pending' then raise exception 'Already decided.'; end if;

  update approvals set status = case when p_approve then 'approved'::approval_status else 'declined' end,
         decided_by = auth.uid(), decided_at = now()
   where id = p_approval returning * into a;

  perform _allow_internal();
  update work_orders set status = 'on_site' where id = w.id and status = 'awaiting_approval';
  perform _end_internal();

  if p_approve then
    update guardrail_flags set resolved_at = now(), resolved_by = auth.uid(), resolution_note = 'Customer approved'
     where work_order_id = w.id and flag in ('po_exceeded','po_near_cap') and resolved_at is null;
  end if;

  perform _notify(w.technician_id, w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Call #%s: customer %s the extra $%s.', w.number, case when p_approve then 'APPROVED' else 'DECLINED' end, a.requested_amount));
  perform _notify_office(w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Call #%s: customer %s the extra $%s.', w.number, case when p_approve then 'approved' else 'declined' end, a.requested_amount));
  return a;
end $$;

-- ---------- Guardrails & completion ----------------------------------
create or replace function run_guardrails(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; rt repair_types; k record; v_missing text; v_extra text;
begin
  select * into w from work_orders where id = p_wo;
  select * into rt from repair_types where id = w.repair_type_id;
  select * into k from compute_costs(p_wo);

  if rt.expected_cost_min is not null and w.total_cost < rt.expected_cost_min then
    perform _raise_flag(p_wo, 'underbilling',
      format('Total $%s is below the usual $%s–$%s for "%s".', w.total_cost, rt.expected_cost_min, rt.expected_cost_max, rt.name));
  end if;
  if rt.expected_cost_max is not null and w.total_cost > rt.expected_cost_max then
    perform _raise_flag(p_wo, 'overbilling',
      format('Total $%s is above the usual $%s–$%s for "%s".', w.total_cost, rt.expected_cost_min, rt.expected_cost_max, rt.name));
  end if;
  if (rt.expected_labor_min is not null and k.raw_labor_minutes < rt.expected_labor_min) or
     (rt.expected_labor_max is not null and k.raw_labor_minutes > rt.expected_labor_max) then
    perform _raise_flag(p_wo, 'labor_out_of_range',
      format('%s min on site; "%s" usually takes %s–%s min.', k.raw_labor_minutes, rt.name, rt.expected_labor_min, rt.expected_labor_max));
  end if;

  -- Kit parts that were not used (possible missed billing)
  select string_agg(pt.name, ', ') into v_missing
  from repair_type_parts rp join parts pt on pt.id = rp.part_id
  where rp.repair_type_id = rt.id
    and not exists (select 1 from parts_used pu where pu.work_order_id = p_wo and pu.part_id = rp.part_id);
  if v_missing is not null and rt.parts_required then
    perform _raise_flag(p_wo, 'parts_missing', 'Usual parts not billed: ' || v_missing);
  end if;

  -- Parts beyond the kit (possible overbilling) — only when a kit is defined
  if exists (select 1 from repair_type_parts where repair_type_id = rt.id) then
    select string_agg(format('%s x%s', pt.name, _qty(pu.quantity)), ', ') into v_extra
    from parts_used pu join parts pt on pt.id = pu.part_id
    left join repair_type_parts rp on rp.repair_type_id = rt.id and rp.part_id = pu.part_id
    where pu.work_order_id = p_wo and (rp.part_id is null or pu.quantity > rp.quantity);
    if v_extra is not null then
      perform _raise_flag(p_wo, 'parts_excessive', 'Beyond the usual kit: ' || v_extra);
    end if;
  end if;
end $$;

create or replace function _refresh_invoice_ready(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _allow_internal();
  update work_orders w set invoice_ready = (w.status = 'completed' and not exists (
      select 1 from guardrail_flags f where f.work_order_id = w.id and f.blocking and f.resolved_at is null))
   where w.id = p_wo;
  perform _end_internal();
end $$;

-- Both sides pay: $5 per completed call each, capped at $50/month per organization,
-- unless a fee_plans row overrides it (e.g. enterprise per-call with no cap).
create or replace function _record_fees(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; fp record; v_month date; v_spent numeric;
begin
  select * into w from work_orders where id = p_wo;
  v_month := date_trunc('month', w.completed_at)::date;
  for fp in
    select o.kind, o.id,
           coalesce(p.per_call, 5.00) as per_call,
           case when p.org_id is null then 50.00 else p.monthly_cap end as monthly_cap
    from (values ('contractor'::org_kind, w.contractor_id), ('customer'::org_kind, w.customer_id)) o(kind, id)
    left join fee_plans p on p.org_kind = o.kind and p.org_id = o.id
  loop
    select coalesce(sum(amount), 0) into v_spent from platform_fees
     where org_kind = fp.kind and org_id = fp.id and billing_month = v_month;
    insert into platform_fees (org_kind, org_id, work_order_id, billing_month, amount)
    values (fp.kind, fp.id, p_wo, v_month,
            case when fp.monthly_cap is null then fp.per_call
                 else least(fp.per_call, greatest(fp.monthly_cap - v_spent, 0)) end)
    on conflict do nothing;
  end loop;
end $$;

-- Returns {"ok":true,...} or {"ok":false,"missing":[{item,message}...]} — never half-completes.
create or replace function tech_complete(p_wo uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare w work_orders := _my_job(p_wo); v_at timestamptz := _device_time(p_at); v_missing jsonb;
begin
  if w.status = 'completed' then return jsonb_build_object('ok', true, 'already', true); end if;
  v_at := greatest(v_at, w.arrived_at);

  select jsonb_agg(jsonb_build_object('item', item, 'message', message)) into v_missing
  from completion_check(p_wo, v_at);
  if v_missing is not null then
    return jsonb_build_object('ok', false, 'missing', v_missing);
  end if;

  perform _allow_internal();
  update work_orders set status = 'completed', completed_at = v_at where id = p_wo;
  perform _end_internal();
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, lat, lon, event, recorded_at)
    values (auth.uid(), p_wo, p_lat, p_lon, 'completed', v_at);
  end if;

  perform _apply_summary(p_wo);
  w := recalc_work_order(p_wo);
  perform run_guardrails(p_wo);
  perform _refresh_invoice_ready(p_wo);
  perform _record_fees(p_wo);

  perform _notify_customer(p_wo, 'completed',
    format('Call #%s completed. Total $%s. Photos and details are in your portal.', w.number, w.total_cost));
  perform _notify_office(p_wo, 'completed', format('Call #%s completed — $%s.', w.number, w.total_cost));
  select * into w from work_orders where id = p_wo;
  return jsonb_build_object('ok', true, 'total_cost', w.total_cost, 'invoice_ready', w.invoice_ready);
end $$;

-- ---------- Office review --------------------------------------------
create or replace function resolve_flag(p_flag uuid, p_note text)
returns guardrail_flags language plpgsql security definer set search_path = public as $$
declare f guardrail_flags; w work_orders;
begin
  select * into f from guardrail_flags where id = p_flag;
  select * into w from work_orders where id = f.work_order_id;
  if not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Add a note explaining the resolution.'; end if;
  update guardrail_flags set resolved_at = now(), resolved_by = auth.uid(), resolution_note = p_note
   where id = p_flag returning * into f;
  perform _refresh_invoice_ready(w.id);
  return f;
end $$;

-- Correct a lifecycle time (phone died, GPS failed). Logged, visible to the customer.
create or replace function override_time(p_wo uuid, p_field text, p_value timestamptz, p_reason text)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders; v_old timestamptz;
begin
  select * into w from work_orders where id = p_wo for update;
  if not exists (select 1 from profiles where id = auth.uid() and active and contractor_id = w.contractor_id
                 and role = 'contractor_admin') then
    raise exception 'Only a contractor admin can override times.';
  end if;
  if w.status = 'invoiced' then raise exception 'Already invoiced.'; end if;
  if p_value > now() then raise exception 'Time cannot be in the future.'; end if;

  execute format('select %I from work_orders where id = $1', p_field) into v_old using p_wo;
  insert into time_overrides (work_order_id, field, old_value, new_value, reason, overridden_by)
  values (p_wo, p_field, v_old, p_value, p_reason, auth.uid());   -- checks field name & reason length

  perform _allow_internal(true);
  execute format('update work_orders set %I = $1 where id = $2', p_field) using p_value, p_wo;
  perform _end_internal();

  select * into w from work_orders where id = p_wo;
  if (w.arrived_at < w.started_at) or (w.completed_at < w.arrived_at) or (w.departed_at < w.arrived_at) then
    raise exception 'Times would be out of order (start ≤ arrive ≤ complete).';
  end if;

  perform _raise_flag(p_wo, 'time_override',
    format('%s changed from %s to %s: %s', p_field, coalesce(v_old::text, 'blank'), p_value, p_reason), false);
  w := recalc_work_order(p_wo);
  -- A correction must not quietly push the bill past what the customer approved.
  if w.po_cap is not null and w.total_cost > effective_cap(p_wo) then
    perform _raise_flag(p_wo, 'po_exceeded',
      format('After time correction, $%s exceeds the approved $%s. Get customer approval or adjust.', w.total_cost, effective_cap(p_wo)), true);
  end if;
  perform _refresh_invoice_ready(p_wo);
  return w;
end $$;

create or replace function mark_exported(p_wo uuid, p_qbo_invoice_id text)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if not is_contractor_office(w.contractor_id) and current_user <> 'service_role' then raise exception 'Not allowed.'; end if;
  if not w.invoice_ready then raise exception 'Resolve all review flags before exporting.'; end if;
  perform _allow_internal();
  update work_orders set status = 'invoiced', qbo_invoice_id = p_qbo_invoice_id, exported_at = now()
   where id = p_wo returning * into w;
  perform _end_internal();
  return w;
end $$;

-- Invoice payload for QuickBooks (and for printing). Phase 5 maps this to QBO's API.
create or replace function invoice_payload(p_wo uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when can_see_work_order(p_wo) or current_user = 'service_role' then
  jsonb_build_object(
    'work_order_number', w.number, 'work_order_id', w.id, 'po_number', w.po_number,
    'customer', cu.name, 'qbo_customer_ref', sa.qbo_customer_ref, 'site', s.name, 'site_address', s.address,
    'equipment', concat_ws(' ', e.manufacturer, e.model, 'S/N ' || e.serial),
    'description', w.work_summary,
    'arrived_at', w.arrived_at, 'completed_at', w.completed_at,
    'lines',
      coalesce((select jsonb_agg(jsonb_build_object('type','part','sku',pt.sku,'name',pt.name,
                 'qty',pu.quantity,'unit_price',pu.unit_price,'amount',pu.total_price) order by pt.name)
                from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = w.id), '[]'::jsonb)
      || jsonb_build_array(jsonb_build_object('type','labor','name','Labor','qty', round(w.labor_minutes_billed / 60.0, 2),
                 'unit_price', c.labor_rate, 'amount', w.total_labor))
      || case when w.total_trip > 0 then jsonb_build_array(jsonb_build_object('type','trip','name','Trip charge',
                 'qty',1,'unit_price',w.total_trip,'amount',w.total_trip)) else '[]'::jsonb end,
    'total', w.total_cost)
  end
  from work_orders w join customers cu on cu.id = w.customer_id join sites s on s.id = w.site_id
  join contractors c on c.id = w.contractor_id
  left join service_agreements sa on sa.contractor_id = w.contractor_id and sa.customer_id = w.customer_id
  left join equipment e on e.id = w.equipment_id
  where w.id = p_wo
$$;
