-- =====================================================================
-- ServicePro v2 — core rules: who-is-who, protection, notifications,
-- pricing, cost engine.
-- Apps READ tables (filtered by row-level security) and WRITE only by
-- calling these functions (Supabase RPC). Functions run as owner and
-- check the caller themselves.
-- =====================================================================

-- ---------- Small utilities ------------------------------------------
create or replace function _allow_internal(p_override boolean default false) returns void
language sql set search_path = public as $$
  select set_config('app.internal', 'on', true),
         set_config('app.override', case when p_override then 'on' else 'off' end, true);
$$;

create or replace function _end_internal() returns void
language sql set search_path = public as $$
  select set_config('app.internal', 'off', true), set_config('app.override', 'off', true);
$$;

create or replace function _qty(n numeric) returns text
language sql immutable set search_path = public as $$
  select trim(trailing '.' from trim(trailing '0' from n::text))
$$;

create or replace function distance_ft(lat1 double precision, lon1 double precision,
                                       lat2 double precision, lon2 double precision)
returns double precision language sql immutable set search_path = public as $$
  select 20902231 * 2 * asin(sqrt(
           power(sin(radians(lat2 - lat1) / 2), 2) +
           cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)))
$$;

-- Phone clocks are trusted within limits (offline sync sends old times).
create or replace function _device_time(p_at timestamptz) returns timestamptz
language plpgsql stable set search_path = public as $$
begin
  if p_at is null then return now(); end if;
  if p_at > now() + interval '5 minutes' then
    raise exception 'Device clock is ahead of server time (%). Check the phone''s date/time settings.', p_at;
  end if;
  if p_at < now() - interval '7 days' then
    raise exception 'Timestamp % is more than 7 days old; the office must enter a time correction.', p_at;
  end if;
  return p_at;
end $$;

create or replace function _hm(minutes int) returns text
language sql immutable set search_path = public as $$
  select case when minutes < 60 then minutes || ' min'
              else (minutes / 60) || ' h ' || (minutes % 60) || ' m' end
$$;

create or replace function po_label(p_wo uuid, p_seq int) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(w.store_po_number, 'PO' || w.number) ||
         case when p_seq = 0 then '' else chr(64 + p_seq) end
  from work_orders w where w.id = p_wo
$$;

-- ---------- Who is calling -------------------------------------------
create or replace function me() returns profiles
language sql stable security definer set search_path = public as $$
  select * from profiles where id = auth.uid() and active
$$;

create or replace function is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and is_platform_admin)
$$;

create or replace function is_contractor_member(p_contractor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and contractor_id = p_contractor)
$$;

-- office = admin, dispatcher or billing
create or replace function is_contractor_office(p_contractor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and contractor_id = p_contractor
                 and (is_org_admin or can_dispatch or can_bill))
$$;

create or replace function is_contractor_dispatcher(p_contractor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and contractor_id = p_contractor
                 and (is_org_admin or can_dispatch))
$$;

create or replace function is_customer_member(p_customer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and customer_id = p_customer)
$$;

create or replace function is_customer_admin(p_customer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active and customer_id = p_customer and is_org_admin)
$$;

-- A given profile can see a given site?
create or replace function profile_sees_site(p_profile uuid, p_site uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles p join sites s on s.id = p_site
    where p.id = p_profile and p.active and (
         p.is_platform_admin
      or (p.customer_id = s.customer_id and (p.all_sites or exists (
            select 1 from profile_sites ps where ps.profile_id = p.id and ps.site_id = s.id)))
      or (p.contractor_id is not null and exists (
            select 1 from customer_contractors cc where cc.contractor_id = p.contractor_id and cc.customer_id = s.customer_id))))
$$;

create or replace function can_see_site(p_site uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select profile_sees_site(auth.uid(), p_site)
$$;

create or replace function can_see_work_order(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from work_orders w join profiles p on p.id = auth.uid() and p.active
    where w.id = p_wo and (
         p.is_platform_admin
      or (p.contractor_id = w.contractor_id and (p.is_org_admin or p.can_dispatch or p.can_bill))
      or (p.contractor_id = w.contractor_id and p.is_technician and exists (
            select 1 from visits v where v.work_order_id = w.id and v.technician_id = p.id))
      or (p.customer_id = w.customer_id and (p.all_sites or exists (
            select 1 from profile_sites ps where ps.profile_id = p.id and ps.site_id = w.site_id)))))
$$;

-- ---------- Notifications --------------------------------------------
create or replace function _wants(p_profile uuid, p_type notify_type) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((p.notify ->> p_type::text)::boolean, true) from profiles p where p.id = p_profile
$$;

create or replace function _notify(p_user uuid, p_wo uuid, p_type notify_type, p_msg text, p_dedupe text default null)
returns void language sql security definer set search_path = public as $$
  insert into notifications (user_id, work_order_id, type, message, dedupe_key)
  select p_user, p_wo, p_type, p_msg, p_dedupe
  where p_user is not null and _wants(p_user, p_type)
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing
$$;

-- Everyone at the customer who can see this site and wants this kind of notice
create or replace function _notify_customer(p_wo uuid, p_type notify_type, p_msg text, p_dedupe text default null)
returns void language sql security definer set search_path = public as $$
  select _notify(p.id, w.id, p_type, p_msg, p_dedupe)
  from work_orders w join profiles p on p.customer_id = w.customer_id and p.active
  where w.id = p_wo and (p.all_sites or exists (select 1 from profile_sites ps where ps.profile_id = p.id and ps.site_id = w.site_id))
$$;

create or replace function _notify_office(p_wo uuid, p_type notify_type, p_msg text, p_dedupe text default null)
returns void language sql security definer set search_path = public as $$
  select _notify(p.id, w.id, p_type, p_msg, p_dedupe)
  from work_orders w join profiles p on p.contractor_id = w.contractor_id and p.active
                                    and (p.is_org_admin or p.can_dispatch or p.can_bill)
  where w.id = p_wo
$$;

-- ---------- Protection triggers --------------------------------------
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
    -- Direct edits may only touch descriptive columns (enforced by column grants too).
    if (to_jsonb(new) - array['issue_description','priority','store_po_number','updated_at'])
       is distinct from (to_jsonb(old) - array['issue_description','priority','store_po_number','updated_at']) then
      raise exception 'That change must go through the app actions, not a direct edit.';
    end if;
    if old.status in ('completed','invoiced','cancelled') and new.issue_description is distinct from old.issue_description then
      raise exception 'Closed work orders cannot be re-described.';
    end if;
  end if;
  return new;
end $$;
create trigger work_orders_guard before update on work_orders for each row execute function _wo_guard();

-- Visit times are write-once except through a logged override.
create or replace function _visit_guard() returns trigger
language plpgsql set search_path = public as $$
declare override boolean := coalesce(current_setting('app.override', true), 'off') = 'on';
begin
  if not override and (
       (old.started_at   is not null and new.started_at   is distinct from old.started_at) or
       (old.arrived_at   is not null and new.arrived_at   is distinct from old.arrived_at) or
       (old.departed_at  is not null and new.departed_at  is distinct from old.departed_at) or
       (old.completed_at is not null and new.completed_at is distinct from old.completed_at) or
       (old.checkin_at   is not null and new.checkin_at   is distinct from old.checkin_at)) then
    raise exception 'Arrival, check-in, departure and completion times cannot be edited. The office can enter a logged correction.';
  end if;
  return new;
end $$;
create trigger visits_guard before update on visits for each row execute function _visit_guard();

-- PO lines: approved/declined decisions are final
create or replace function _po_line_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.status <> 'pending' and (new.status, new.amount) is distinct from (old.status, old.amount) then
    raise exception 'A decided PO line cannot be changed. Request a new letter instead.';
  end if;
  return new;
end $$;
create trigger po_lines_guard before update on po_lines for each row execute function _po_line_guard();

create or replace function _audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (table_name, row_id, action, actor, old_data, new_data)
  values (tg_table_name,
          ((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end) ->> 'id')::uuid,
          tg_op, auth.uid(),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return null;
end $$;
do $$ declare t text; begin
  foreach t in array array['work_orders','visits','po_lines','parts_used','parts_orders','guardrail_flags',
                           'equipment','time_overrides','photos','warranties','agreements','time_entries',
                           'approval_chains','approval_chain_steps','profiles','pm_plans'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on %1$I for each row execute function _audit()', t);
  end loop;
end $$;

-- ---------- Pricing: diagnosis amount (4 layers) ---------------------
create or replace function site_region_pct(p_site uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select r.adjust_pct from sites s join cost_regions r on r.id = s.region_id where s.id = p_site),
    (select r.adjust_pct from sites s join region_zip3 z on z.zip3 = left(s.zip, 3)
                          join cost_regions r on r.id = z.region_id where s.id = p_site),
    0)
$$;

create or replace function is_after_hours(p_site uuid, p_at timestamptz default now()) returns boolean
language sql stable security definer set search_path = public as $$
  with x as (
    select (p_at at time zone s.timezone) as lt from sites s where s.id = p_site)
  select extract(isodow from lt) in (6, 7)
      or exists (select 1 from holidays h where h.day = lt::date)
      or lt::time < ps.business_start or lt::time >= ps.business_end
  from x, platform_settings ps
$$;

create or replace function active_agreement(p_contractor uuid, p_site uuid, p_on date default current_date)
returns agreements language sql stable security definer set search_path = public as $$
  select a.* from agreements a join sites s on s.id = p_site
  where a.contractor_id = p_contractor and a.customer_id = s.customer_id and a.status = 'active'
    and p_on between a.starts_on and a.ends_on
    and (a.all_sites or exists (select 1 from agreement_sites x where x.agreement_id = a.id and x.site_id = p_site))
  order by a.starts_on desc limit 1
$$;

-- What the store authorizes for diagnosis. Not a price contractors must charge:
-- the contractor bills actual cost, up to this amount.
create or replace function diagnosis_amount(p_site uuid, p_issue uuid, p_contractor uuid, p_at timestamptz default now())
returns numeric language plpgsql stable security definer set search_path = public as $$
declare a agreements; base numeric; ps platform_settings;
begin
  select * into ps from platform_settings;
  a := active_agreement(p_contractor, p_site, (p_at at time zone 'UTC')::date);
  if a.id is not null and a.diagnosis_amount is not null then
    base := a.diagnosis_amount;                                         -- layer 4
  else
    select diagnosis_amount into base from issue_types where id = p_issue;  -- layer 1
    if base is null then return null; end if;
    base := base * (1 + site_region_pct(p_site) / 100);                 -- layer 2
  end if;
  if is_after_hours(p_site, p_at) then
    base := base * (1 + ps.after_hours_pct / 100);                      -- layer 3
  end if;
  return round(base, 0);
end $$;

-- ---------- Cost engine ----------------------------------------------
create or replace function part_price(p_part uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(pt.unit_price, round(coalesce(pt.unit_cost, 0) * (1 + c.parts_markup_pct / 100), 2))
  from parts pt join contractors c on c.id = pt.contractor_id where pt.id = p_part
$$;

create or replace function effective_cap(p_wo uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when count(*) = 0 then null else coalesce(sum(amount) filter (where status = 'approved'), 0) end
  from po_lines where work_order_id = p_wo
$$;

-- Does the job's agreement cover labor / parts / PM?
create or replace function _coverage(p_wo uuid) returns table (labor boolean, parts boolean, pm boolean,
  labor_disc numeric, parts_disc numeric)
language sql stable security definer set search_path = public as $$
  select coalesce(a.coverage in ('pm_labor','full'), false),
         coalesce(a.coverage = 'full', false),
         a.id is not null,
         coalesce(a.labor_discount_pct, 0),
         coalesce(a.parts_discount_pct, 0)
  from work_orders w left join agreements a on a.id = w.agreement_id
  where w.id = p_wo
$$;

-- Labor for one visit, ending at p_end if it is still open.
create or replace function compute_visit(p_visit uuid, p_end timestamptz default null)
returns table (raw_minutes int, billed_minutes int, amount numeric)
language plpgsql stable security definer set search_path = public as $$
declare v visits; w work_orders; c contractors; cov record; rate numeric; e timestamptz;
begin
  select * into v from visits where id = p_visit;
  select * into w from work_orders where id = v.work_order_id;
  select * into c from contractors where id = w.contractor_id;
  select * into cov from _coverage(w.id);
  raw_minutes := 0; billed_minutes := 0; amount := 0;
  if v.arrived_at is null then return next; return; end if;
  e := coalesce(v.completed_at, v.departed_at, p_end, now());
  raw_minutes := greatest(0, ceil(extract(epoch from (e - v.arrived_at)) / 60))::int;
  if c.bill_travel_time and v.started_at is not null then
    raw_minutes := raw_minutes + greatest(0, ceil(extract(epoch from (v.arrived_at - v.started_at)) / 60))::int;
  end if;
  billed_minutes := greatest(c.min_labor_minutes,
                             (ceil(raw_minutes::numeric / c.labor_increment_min) * c.labor_increment_min)::int);
  rate := case when w.after_hours then coalesce(c.after_hours_labor_rate, c.labor_rate) else c.labor_rate end;
  if cov.labor or (w.kind = 'pm' and (cov.pm or w.flat_amount > 0)) then
    amount := 0;                                     -- covered by agreement / flat PM price
  else
    amount := round(billed_minutes::numeric / 60 * rate * (1 - cov.labor_disc / 100), 2);
  end if;
  return next;
end $$;

create or replace function compute_costs(p_wo uuid, p_end timestamptz default null)
returns table (labor_minutes int, parts numeric, labor numeric, trip numeric, flat numeric, total numeric,
               cost_labor numeric, cost_parts numeric)
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; c contractors; cov record; k record; v record; n_trips int := 0;
begin
  select * into w from work_orders where id = p_wo;
  select * into c from contractors where id = w.contractor_id;
  select * into cov from _coverage(p_wo);
  labor_minutes := 0; labor := 0; cost_labor := 0;
  for v in select vi.*, p.hourly_cost from visits vi join profiles p on p.id = vi.technician_id
           where vi.work_order_id = p_wo and vi.status <> 'cancelled' loop
    select * into k from compute_visit(v.id, p_end);
    labor_minutes := labor_minutes + k.billed_minutes;
    labor := labor + k.amount;
    cost_labor := cost_labor + round(k.raw_minutes::numeric / 60 * coalesce(v.hourly_cost, 0), 2);
    if v.arrived_at is not null then n_trips := n_trips + 1; end if;
  end loop;
  select coalesce(sum(total_price), 0), coalesce(sum(quantity * coalesce(unit_cost, 0)), 0)
    into parts, cost_parts from parts_used where work_order_id = p_wo;
  trip := case when cov.labor or (w.kind = 'pm' and (cov.pm or w.flat_amount > 0)) then 0
               else n_trips * c.trip_charge end;
  flat := w.flat_amount;
  total := parts + labor + trip + flat;
  return next;
end $$;

create or replace function _raise_flag(p_wo uuid, p_flag flag_type, p_desc text,
  p_blocking boolean default true, p_customer_visible boolean default false)
returns void language sql security definer set search_path = public as $$
  insert into guardrail_flags (work_order_id, flag, description, blocking, visible_to_customer)
  values (p_wo, p_flag, p_desc, p_blocking, p_customer_visible)
  on conflict (work_order_id, flag) where resolved_at is null
  do update set description = excluded.description
$$;

create or replace function recalc_work_order(p_wo uuid) returns work_orders
language plpgsql security definer set search_path = public as $$
declare w work_orders; k record; v record; vk record; cap numeric; warn numeric;
begin
  for v in select id from visits where work_order_id = p_wo and status <> 'cancelled' loop
    select * into vk from compute_visit(v.id);
    update visits set labor_minutes_raw = vk.raw_minutes, labor_minutes_billed = vk.billed_minutes,
                      labor_amount = vk.amount where id = v.id;
  end loop;
  select * into k from compute_costs(p_wo);
  perform _allow_internal();
  update work_orders set labor_minutes_billed = k.labor_minutes, total_parts = k.parts, total_labor = k.labor,
         total_trip = k.trip, total_cost = k.total, cost_labor = k.cost_labor, cost_parts = k.cost_parts
   where id = p_wo returning * into w;
  perform _end_internal();

  cap := effective_cap(p_wo);
  if cap is not null and cap > 0 and w.status in ('on_site','awaiting_approval') then
    select po_warn_pct into warn from contractors where id = w.contractor_id;
    if w.total_cost >= cap * warn / 100 and not exists (
         select 1 from guardrail_flags where work_order_id = p_wo and flag = 'po_near_cap' and resolved_at is null) then
      perform _raise_flag(p_wo, 'po_near_cap',
        format('Cost $%s is at %s%% of the approved $%s.', w.total_cost, round(w.total_cost / cap * 100), cap), false);
      perform _notify_customer(p_wo, 'guardrail_flag',
        format('Call #%s is at $%s of the $%s approved on %s.', w.number, w.total_cost, cap, po_label(p_wo, 0)),
        'near_cap:' || p_wo);
    end if;
  end if;
  return w;
end $$;
