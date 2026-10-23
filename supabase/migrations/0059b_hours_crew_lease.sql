-- 1) Regular hours per contractor (set by the customer), after-hours split on the call, PM calls never overtime
-- 2) After hours on the contractor's side: after-hours phone and an on-call rotation
-- 3) "Can it wait until morning?": a store can hold a non-emergency after-hours call until the contractor's next regular hour
-- 4) Crew size: the lead reports helpers when he arrives, the person on site confirms, helper time is verified
-- 5) Leased equipment with full coverage, with the lease company's contact

-- Small helper: patch a live function body in place (fails loudly if the text isn't there)
create or replace function _patch_fn(p_fn regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare src text := pg_get_functiondef(p_fn);
begin
  if position(p_old in src) = 0 then raise exception 'patch target not found in %: %', p_fn, left(p_old, 80); end if;
  execute replace(src, p_old, p_new);
end $$;
revoke execute on function _patch_fn(regprocedure, text, text) from public, anon, authenticated;

-- ============ 1) Regular hours ============
-- {"mon":["07:00","17:00"], ..., "sun":null, "holidays":"after"|"regular", "pm_regular":true}
-- A day with no window is after hours all day. "24:00" as an end means midnight.
alter table customer_contractors add column if not exists regular_hours jsonb;

create or replace function _after_hours_at(p_site uuid, p_contractor uuid, p_at timestamptz) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare s sites; h jsonb; lt timestamp; win jsonb;
begin
  select * into s from sites where id = p_site;
  select cc.regular_hours into h from customer_contractors cc where cc.customer_id = s.customer_id and cc.contractor_id = p_contractor;
  if h is null then return is_after_hours(p_site, p_at); end if;
  lt := p_at at time zone coalesce(s.timezone, 'America/Chicago');
  if coalesce(h->>'holidays', 'after') = 'after' and exists (select 1 from holidays where day = lt::date) then return true; end if;
  win := h -> lower(to_char(lt, 'dy'));
  if win is null or jsonb_typeof(win) <> 'array' or jsonb_array_length(win) < 2 then return true; end if;
  return not (lt::time >= (win->>0)::time and (win->>1 = '24:00' or lt::time < (win->>1)::time));
end $$;

-- Is a new call after hours? Maintenance calls never are when the customer says so.
create or replace function _call_after_hours(p_site uuid, p_contractor uuid, p_kind wo_kind) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_kind = 'pm' and coalesce((select (cc.regular_hours->>'pm_regular')::boolean from customer_contractors cc join sites s on s.customer_id = cc.customer_id
                                                 where s.id = p_site and cc.contractor_id = p_contractor), false)
              then false else _after_hours_at(p_site, p_contractor, now()) end
$$;

-- The next regular-hours moment (for calls held until morning)
create or replace function _next_regular(p_site uuid, p_contractor uuid, p_from timestamptz) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare t timestamptz := date_trunc('hour', p_from) + make_interval(mins => (floor(extract(minute from p_from) / 15)::int + 1) * 15); i int;
begin
  for i in 1 .. 7 * 96 loop
    if not _after_hours_at(p_site, p_contractor, t) then return t; end if;
    t := t + interval '15 minutes';
  end loop;
  return p_from + interval '12 hours';
end $$;

create or replace function set_regular_hours(p_contractor uuid, p_hours jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); d text; win jsonb;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to change contractor terms.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if p_hours is not null then
    foreach d in array array['mon','tue','wed','thu','fri','sat','sun'] loop
      win := p_hours -> d;
      if win is not null and jsonb_typeof(win) = 'array' then
        begin
          if (win->>0)::time >= (case when win->>1 = '24:00' then '23:59:59'::time else (win->>1)::time end) then
            raise exception 'On %, the regular hours have to end after they start.', d;
          end if;
        exception when invalid_datetime_format or datetime_field_overflow then raise exception 'Use times like 07:00 and 17:00.';
        end;
      end if;
    end loop;
  end if;
  update customer_contractors set regular_hours = p_hours where customer_id = m.customer_id and contractor_id = p_contractor;
  if not found then raise exception 'Not your contractor.'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function set_regular_hours(uuid, jsonb) from public, anon;
grant execute on function set_regular_hours(uuid, jsonb) to authenticated;

-- For the call form: is it after hours for this contractor right now, when do regular hours start, and the two rates
create or replace function after_hours_info(p_site uuid, p_contractor uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s sites; r jsonb;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not can_see_site(p_site) then raise exception 'Not allowed.'; end if;
  r := rate_card(s.customer_id, p_contractor, current_date) -> 'current' -> 'rates';
  return jsonb_build_object('after', _after_hours_at(p_site, p_contractor, now()),
    'next_regular', _next_regular(p_site, p_contractor, now()),
    'next_regular_local', to_char(_next_regular(p_site, p_contractor, now()) at time zone coalesce(s.timezone, 'America/Chicago'), 'FMHH12:MI AM Dy'),
    'regular_rate', r->'regular', 'after_rate', r->'after_hours');
end $$;
revoke execute on function after_hours_info(uuid, uuid) from public, anon;
grant execute on function after_hours_info(uuid, uuid) to authenticated;

-- ============ 2) After hours, contractor side ============
alter table contractors add column if not exists after_hours_phone text;

create table if not exists oncall (
  id            uuid primary key default gen_random_uuid(),
  contractor_id uuid not null references contractors(id) on delete cascade,
  profile_id    uuid not null references profiles(id) on delete cascade,
  starts_on     date not null,
  ends_on       date not null check (ends_on >= starts_on),
  cancelled     boolean not null default false,
  created_at    timestamptz not null default now(),
  created_by    uuid references profiles(id)
);
alter table oncall enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'oncall' and policyname = 'oncall_read') then
    create policy oncall_read on oncall for select using (is_contractor_office(contractor_id) or profile_id = auth.uid());
  end if;
end $$;

create or replace function _oncall_now(p_contractor uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select o.profile_id from oncall o join profiles p on p.id = o.profile_id and p.active
   where o.contractor_id = p_contractor and not o.cancelled and current_date between o.starts_on and o.ends_on
   order by o.created_at desc limit 1
$$;

create or replace function save_oncall(p_profile uuid, p_starts date, p_ends date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); nid uuid;
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Only your office can set who is on call.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if not exists (select 1 from profiles where id = p_profile and contractor_id = m.contractor_id and active) then raise exception 'Pick someone on your team.'; end if;
  if p_starts is null or p_ends is null or p_ends < p_starts then raise exception 'Pick the first and last day.'; end if;
  insert into oncall (contractor_id, profile_id, starts_on, ends_on, created_by) values (m.contractor_id, p_profile, p_starts, p_ends, m.id) returning id into nid;
  return jsonb_build_object('ok', true, 'id', nid);
end $$;
revoke execute on function save_oncall(uuid, date, date) from public, anon;
grant execute on function save_oncall(uuid, date, date) to authenticated;

create or replace function cancel_oncall(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Only your office can change who is on call.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  update oncall set cancelled = true where id = p_id and contractor_id = m.contractor_id;
  return jsonb_build_object('ok', found);
end $$;
revoke execute on function cancel_oncall(uuid) from public, anon;
grant execute on function cancel_oncall(uuid) to authenticated;

create or replace function set_after_hours_phone(p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Only your office can change this.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  update contractors set after_hours_phone = nullif(trim(p_phone), '') where id = m.contractor_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function set_after_hours_phone(text) from public, anon;
grant execute on function set_after_hours_phone(text) to authenticated;

-- ============ 3) Hold until morning ============
alter table work_orders add column if not exists hold_until timestamptz;
alter table work_orders add column if not exists hold_released_at timestamptz;

create table if not exists call_hold_requests (
  profile_id uuid primary key references profiles(id) on delete cascade,
  made_at    timestamptz
);
alter table call_hold_requests enable row level security;

-- The call form says "wait until morning" just before it creates the call
create or replace function store_hold_next_call() returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null then raise exception 'Not allowed.'; end if;
  insert into call_hold_requests (profile_id, made_at) values (m.id, now())
    on conflict (profile_id) do update set made_at = now();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function store_hold_next_call() from public, anon;
grant execute on function store_hold_next_call() to authenticated;

create or replace function _take_hold(p_wo uuid, p_by uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare w work_orders; until timestamptz; cc customer_contractors;
begin
  update call_hold_requests set made_at = null where profile_id = p_by and made_at > now() - interval '3 minutes';
  if not found then return false; end if;
  select * into w from work_orders where id = p_wo;
  if w.priority = 1 or w.mode <> 'verify' then return false; end if;
  until := _next_regular(w.site_id, w.contractor_id, now());
  cc := _cc(w.customer_id, w.contractor_id);
  perform _allow_internal();
  update work_orders set hold_until = until, after_hours = false,
         accept_due_at = until + make_interval(mins => coalesce(cc.accept_normal_min, 120)) where id = p_wo;
  perform _end_internal();
  perform _notify_customer(p_wo, 'new_call', format('Call #%s is saved and goes to %s at %s (their regular hours), so no after-hours charge.',
    w.number, (select name from contractors where id = w.contractor_id), _local(until, w.site_id, 'FMHH12:MI AM Dy')), 'hold:' || p_wo);
  return true;
end $$;
revoke execute on function _take_hold(uuid, uuid) from public, anon, authenticated;

create or replace function release_held_calls() returns int
language plpgsql security definer set search_path = public as $$
declare w record; n int := 0;
begin
  for w in select wo.*, s.name site_name from work_orders wo join sites s on s.id = wo.site_id
            where wo.hold_until is not null and wo.hold_released_at is null and wo.hold_until <= now() and wo.status <> 'cancelled' loop
    perform _allow_internal();
    update work_orders set hold_released_at = now() where id = w.id;
    perform _end_internal();
    perform _notify_office(w.id, 'new_call', format('New PO call #%s (%s) at %s: %s. Held overnight at the customer''s request. Please accept by %s.',
      w.number, _po((select x from work_orders x where x.id = w.id)), w.site_name, w.issue_description, _local(w.accept_due_at, w.site_id, 'HH12:MI AM Dy')), 'held:' || w.id);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function release_held_calls() from public, anon, authenticated;

-- ============ 4) Crew ============
alter table visits add column if not exists crew_helpers int not null default 0 check (crew_helpers between 0 and 20);
alter table visits add column if not exists crew_names text;
alter table visits add column if not exists crew_set_at timestamptz;
alter table visits add column if not exists crew_log jsonb not null default '[]';
alter table visits add column if not exists crew_confirmed boolean;
alter table visits add column if not exists crew_confirmed_at timestamptz;
alter table visits add column if not exists crew_confirmed_by uuid;   -- no foreign key: the apps join visits to profiles by technician only

-- The lead says who's with him: right after "I'm here", and again if the crew changes ("a helper left at 2:10")
create or replace function tech_set_crew(p_visit uuid, p_helpers int, p_names text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v visits; w work_orders; first boolean; more boolean;
begin
  select * into v from visits where id = p_visit;
  if v.id is null then raise exception 'Unknown visit.'; end if;
  select * into w from work_orders where id = v.work_order_id;
  if v.technician_id is distinct from auth.uid() and not is_contractor_office(w.contractor_id) then raise exception 'Not your job.'; end if;
  if v.status <> 'on_site' or v.arrived_at is null then raise exception 'Tap "I''m here" first.'; end if;
  if p_helpers is null or p_helpers < 0 or p_helpers > 20 then raise exception 'Pick 0 to 20 helpers.'; end if;
  first := v.crew_set_at is null;
  more := not first and p_helpers > v.crew_helpers;
  perform _allow_internal();
  update visits set crew_helpers = p_helpers, crew_names = coalesce(nullif(trim(p_names), ''), crew_names),
         crew_set_at = coalesce(crew_set_at, now()),
         crew_log = crew_log || jsonb_build_array(jsonb_build_object('at', case when first then v.arrived_at else now() end, 'helpers', p_helpers)),
         crew_confirmed = case when first or more then null else crew_confirmed end,
         crew_confirmed_at = case when first or more then null else crew_confirmed_at end,
         crew_confirmed_by = case when first or more then null else crew_confirmed_by end
   where id = p_visit;
  perform _end_internal();
  if not first then
    perform _notify_customer(w.id, 'arrival', format('Call #%s: %s now has %s on site%s.', w.number,
      (select full_name from profiles where id = v.technician_id),
      case when p_helpers = 0 then 'no helpers' when p_helpers = 1 then '1 helper' else p_helpers || ' helpers' end,
      case when more then ' — please confirm on the call' else '' end));
  end if;
  return jsonb_build_object('ok', true, 'helpers', p_helpers);
end $$;
revoke execute on function tech_set_crew(uuid, int, text) from public, anon;
grant execute on function tech_set_crew(uuid, int, text) to authenticated;

-- The person on site confirms the count (Yes / No)
create or replace function store_confirm_crew(p_visit uuid, p_ok boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); v visits; w work_orders; tech text;
begin
  select * into v from visits where id = p_visit;
  select * into w from work_orders where id = v.work_order_id;
  if v.id is null or m.customer_id is distinct from w.customer_id or not profile_sees_site(m.id, w.site_id) then raise exception 'Not allowed.'; end if;
  if v.crew_set_at is null then raise exception 'The technician hasn''t said who''s with him yet.'; end if;
  tech := (select full_name from profiles where id = v.technician_id);
  perform _allow_internal();
  update visits set crew_confirmed = p_ok, crew_confirmed_at = now(), crew_confirmed_by = m.id where id = p_visit;
  perform _end_internal();
  if not p_ok then
    perform _raise_flag(w.id, 'crew_mismatch', format('%s said %s on site; %s said that isn''t right.', tech,
      case v.crew_helpers when 0 then 'he was alone' when 1 then 'he had 1 helper' else 'he had ' || v.crew_helpers || ' helpers' end, m.full_name), false, true);
    perform _notify_office(w.id, 'guardrail_flag', format('Call #%s: %s at the location says the crew size %s reported isn''t right.', w.number, m.full_name, tech));
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function store_confirm_crew(uuid, boolean) from public, anon;
grant execute on function store_confirm_crew(uuid, boolean) to authenticated;

-- Verified time now includes helpers (billable hours = tech + helpers) and the regular / after-hours split
create or replace function _verified(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; cc customer_contractors; r record; e timestamptz; arr jsonb := '[]';
  onsite int; travel int; tcount int; away int; away_ver int; bill int; hmin int; hbill int; amin int; seg record; t timestamptz; pm_reg boolean;
  t_on int := 0; t_tr int := 0; t_trc int := 0; t_pr int := 0; t_prv int := 0; t_bill int := 0; t_h int := 0; t_hb int := 0; t_after int := 0; inc int;
begin
  select * into w from work_orders where id = p_wo;
  cc := _cc(w.customer_id, w.contractor_id);
  inc := coalesce(cc.increment_min, 15);
  pm_reg := w.kind = 'pm' and coalesce((cc.regular_hours->>'pm_regular')::boolean, false);
  for r in select v.*, p.full_name tech from visits v join profiles p on p.id = v.technician_id
            where v.work_order_id = p_wo and v.status <> 'cancelled' and v.arrived_at is not null order by v.visit_no loop
    e := coalesce(r.completed_at, r.departed_at, now());
    select coalesce(sum(ceil(extract(epoch from (coalesce(pr.returned_at, e) - pr.left_at)) / 60)), 0),
           coalesce(sum(ceil(extract(epoch from (coalesce(pr.returned_at, e) - pr.left_at)) / 60)) filter (where pr.at_supplier_at is not null and pr.returned_at is not null), 0)
      into away, away_ver from parts_runs pr where pr.visit_id = r.id;
    onsite := greatest(0, ceil(extract(epoch from (e - r.arrived_at)) / 60)::int - away);
    travel := case when r.started_at is not null then greatest(0, ceil(extract(epoch from (r.arrived_at - r.started_at)) / 60))::int else 0 end;
    tcount := case coalesce(cc.pays_travel, 'yes') when 'yes' then travel when 'after_hours' then case when w.after_hours then travel else 0 end else 0 end;
    bill := greatest(round(coalesce(cc.min_hours, 1) * 60)::int, (ceil((onsite + away + tcount)::numeric / inc) * inc)::int);
    -- helpers: each crew entry counts from its time until the next change or the end of the visit
    hmin := 0;
    for seg in select (x->>'at')::timestamptz at_, (x->>'helpers')::int n,
                      lead((x->>'at')::timestamptz) over (order by (x->>'at')::timestamptz) nxt
                 from jsonb_array_elements(r.crew_log) x loop
      hmin := hmin + seg.n * greatest(0, ceil(extract(epoch from (least(coalesce(seg.nxt, e), e) - greatest(seg.at_, r.arrived_at))) / 60))::int;
    end loop;
    hbill := case when hmin > 0 then (ceil(hmin::numeric / inc) * inc)::int else 0 end;
    -- after-hours minutes on site (5-minute steps, up to a day)
    amin := 0;
    if not pm_reg then
      t := r.arrived_at;
      while t < e and t < r.arrived_at + interval '24 hours' loop
        if _after_hours_at(w.site_id, w.contractor_id, t) then amin := amin + 5; end if;
        t := t + interval '5 minutes';
      end loop;
      amin := least(amin, ceil(extract(epoch from (e - r.arrived_at)) / 60)::int);
    end if;
    arr := arr || jsonb_build_object('visit_id', r.id, 'visit_no', r.visit_no, 'tech', r.tech, 'started_at', r.started_at,
      'arrived_at', r.arrived_at, 'left_at', r.completed_at, 'arrival_by_store', r.arrival_source = 'store',
      'checkin_verified', r.checkin_verified, 'outcome', r.outcome, 'open', r.completed_at is null,
      'onsite_min', onsite, 'travel_min', travel, 'travel_counted_min', tcount, 'parts_run_min', away,
      'parts_run_unverified_min', away - away_ver, 'billable_min', bill, 'trip', _trip(r.id),
      'helpers', r.crew_helpers, 'crew_names', r.crew_names, 'crew_set', r.crew_set_at is not null, 'crew_confirmed', r.crew_confirmed,
      'helper_min', hmin, 'helper_billable_min', hbill, 'after_hours_min', amin);
    t_on := t_on + onsite; t_tr := t_tr + travel; t_trc := t_trc + tcount; t_pr := t_pr + away; t_prv := t_prv + (away - away_ver); t_bill := t_bill + bill;
    t_h := t_h + hmin; t_hb := t_hb + hbill; t_after := t_after + amin;
  end loop;
  return jsonb_build_object('visits', arr, 'pays_travel', coalesce(cc.pays_travel, 'yes'), 'min_hours', cc.min_hours, 'increment_min', inc,
    'onsite_h', round(t_on / 60.0, 2), 'travel_h', round(t_tr / 60.0, 2), 'travel_counted_h', round(t_trc / 60.0, 2),
    'parts_run_h', round(t_pr / 60.0, 2), 'parts_run_unverified_h', round(t_prv / 60.0, 2),
    'verified_h', round((t_on + t_trc + t_pr) / 60.0, 2),
    'tech_billable_h', round(t_bill / 60.0, 2), 'helper_h', round(t_h / 60.0, 2), 'helper_billable_h', round(t_hb / 60.0, 2),
    'billable_h', round((t_bill + t_hb) / 60.0, 2),
    'after_hours_h', round(t_after / 60.0, 2), 'regular_h', round(greatest(0, t_on - t_after) / 60.0, 2),
    'nte', w.nte, 'travel_area_mi', (select travel_area_miles from customers where id = w.customer_id));
end $$;

-- ============ 5) Leased equipment ============
alter table equipment add column if not exists lease_full boolean not null default false;
alter table equipment add column if not exists lease_company text;
alter table equipment add column if not exists lease_contact text;
alter table equipment add column if not exists lease_phone text;
alter table equipment add column if not exists lease_email text;
alter table equipment add column if not exists lease_note text;

create or replace function set_equipment_lease(p_equipment uuid, p_full boolean, p_company text, p_contact text, p_phone text, p_email text, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites;
begin
  select st.* into s from sites st join equipment e on e.site_id = st.id where e.id = p_equipment;
  if s.id is null or m.customer_id is distinct from s.customer_id or not store_can(m.customer_id, 'equipment') or not profile_sees_site(m.id, s.id) then
    raise exception 'You don''t have permission to change this equipment.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if coalesce(p_full, false) and nullif(trim(p_company), '') is null then raise exception 'Enter the company it''s leased from.'; end if;
  if coalesce(p_full, false) and nullif(trim(p_phone), '') is null and nullif(trim(p_email), '') is null then raise exception 'Enter a phone or email for the lease company.'; end if;
  perform _allow_internal(true);
  update equipment set lease_full = coalesce(p_full, false), lease_company = nullif(trim(p_company), ''), lease_contact = nullif(trim(p_contact), ''),
         lease_phone = nullif(trim(p_phone), ''), lease_email = nullif(trim(p_email), ''), lease_note = nullif(trim(p_note), '') where id = p_equipment;
  perform _end_internal();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function set_equipment_lease(uuid, boolean, text, text, text, text, text) from public, anon;
grant execute on function set_equipment_lease(uuid, boolean, text, text, text, text, text) to authenticated;

-- ============ Patches to existing functions ============
-- New calls: the contractor's own regular hours; hold until morning; on-call alert; leased-unit flag
select from _patch_fn('_create_call(uuid,uuid,text,uuid,smallint,text,wo_kind,uuid,boolean,uuid,uuid,text,numeric,text)'::regprocedure,
  'v_after := is_after_hours(p_site);', 'v_after := _call_after_hours(p_site, v_contractor, p_kind);');
select from _patch_fn('_create_call(uuid,uuid,text,uuid,smallint,text,wo_kind,uuid,boolean,uuid,uuid,text,numeric,text)'::regprocedure,
  '  perform _repeat_check(w.id);' || chr(10),
  '  perform _repeat_check(w.id);' || chr(10) ||
  '  if p_equipment is not null and exists (select 1 from equipment where id = p_equipment and lease_full) then' || chr(10) ||
  '    perform _raise_flag(w.id, ''leased_unit'', (select format(''This unit is leased from %s with full maintenance and repair coverage. Repairs should go to them%s. A bill for this call may not be owed.'', coalesce(lease_company, ''the leasing company''), coalesce('' ('' || coalesce(lease_phone, lease_email) || '')'', '''')) from equipment where id = p_equipment), false, true);' || chr(10) ||
  '  end if;' || chr(10) ||
  '  if p_side = ''store'' and v_after and _take_hold(w.id, p_by) then select * into w from work_orders where id = w.id; return w; end if;' || chr(10));
select from _patch_fn('_create_call(uuid,uuid,text,uuid,smallint,text,wo_kind,uuid,boolean,uuid,uuid,text,numeric,text)'::regprocedure,
  '  -- Warranty heads-up for both sides',
  '  if v_after and p_side <> ''contractor'' and _oncall_now(v_contractor) is not null then' || chr(10) ||
  '    perform _notify(_oncall_now(v_contractor), w.id, ''new_call'', format(''AFTER HOURS — you are on call: new %scall #%s at %s: %s.'',' || chr(10) ||
  '      case when w.priority = 1 then ''EMERGENCY '' else '''' end, w.number, s.name, w.issue_description), ''oncall:'' || w.id);' || chr(10) ||
  '  end if;' || chr(10) ||
  '  -- Warranty heads-up for both sides');

-- The bill check knows about leased units; auto-approve never applies to them
select from _patch_fn('_invoice_check(uuid)'::regprocedure,
  E'''auto_approve'', (select c.auto_approve_bills from customers c join work_orders w on w.customer_id = c.id where w.id = p_wo));',
  E'''auto_approve'', (select c.auto_approve_bills from customers c join work_orders w on w.customer_id = c.id where w.id = p_wo),\n    ''leased_unit'', (select jsonb_build_object(''company'', e.lease_company, ''contact'', e.lease_contact, ''phone'', e.lease_phone, ''email'', e.lease_email, ''note'', e.lease_note)\n                    from work_orders w join equipment e on e.id = w.equipment_id where w.id = p_wo and e.lease_full));');
select from _patch_fn('send_bill(uuid,text,numeric,boolean,numeric,text,boolean)'::regprocedure,
  'and coalesce((select auto_approve_bills from customers where id = w.customer_id), false);',
  'and coalesce((select auto_approve_bills from customers where id = w.customer_id), false)' || chr(10) ||
  '          and not exists (select 1 from equipment e where e.id = w.equipment_id and e.lease_full);');

-- The tech app gets the crew fields
select from _patch_fn('tech_jobs()'::regprocedure,
  '''checkin_required'', v.checkin_required,',
  '''checkin_required'', v.checkin_required, ''crew_helpers'', v.crew_helpers, ''crew_set_at'', v.crew_set_at, ''crew_names'', v.crew_names, ''crew_confirmed'', v.crew_confirmed,');

-- QR page: say when a unit is leased, with who to call
select from _patch_fn('qr_info(uuid)'::regprocedure,
  '''place_word'', (select place_word from customers where id = s.customer_id),',
  '''place_word'', (select place_word from customers where id = s.customer_id),' || chr(10) ||
  '    ''lease'', case when e.lease_full then jsonb_build_object(''company'', e.lease_company, ''phone'', e.lease_phone, ''email'', e.lease_email) end,');

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-release-held', '*/5 * * * *', 'select public.release_held_calls()');
  end if;
end $$;
