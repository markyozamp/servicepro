-- Crew on calls (Time Verify and Base): every helper and apprentice checks in and out of the call on his own phone,
-- location-checked at both ends (the location's area, at least 1,000 ft). Only time between his own verified
-- check-in and check-out counts as verified. The lead can record "arrived" / "left" for someone without the app
-- (marked "recorded by the lead", not verified). Leaving or finishing asks about anyone still checked in.
-- "Switch to another job": check out here, then check in at the next one. Each call bills only that person's hours there.
-- The lead's headcount ("2 helpers with me", confirmed by the store) stays as the headcount; helper hours now come
-- from the crew's own check-ins.

alter table profiles add column if not exists crew_role text check (crew_role in ('helper', 'apprentice'));

create table if not exists visit_crew (
  id            uuid primary key default gen_random_uuid(),
  visit_id      uuid not null references visits(id) on delete cascade,
  work_order_id uuid not null,
  contractor_id uuid not null,
  profile_id    uuid,                                   -- null: someone without the app, named by the lead
  name          text not null,
  role          text not null default 'helper' check (role in ('helper', 'apprentice', 'tech')),
  arrived_at    timestamptz not null,
  arrived_by    text not null check (arrived_by in ('self', 'lead')),
  arrived_ok    boolean not null default false,         -- his own phone, inside the area
  arrived_ft    int,
  left_at       timestamptz,
  left_by       text check (left_by in ('self', 'lead', 'checkout')),
  left_ok       boolean not null default false,
  left_ft       int,
  created_at    timestamptz not null default now()
);
create index if not exists visit_crew_visit on visit_crew (visit_id);
create index if not exists visit_crew_person on visit_crew (profile_id) where left_at is null;
create unique index if not exists visit_crew_open on visit_crew (profile_id) where left_at is null and profile_id is not null;
alter table visit_crew enable row level security;

-- Distance from the location in feet, and whether it's inside the crew area
create or replace function _crew_where(p_site uuid, p_lat float8, p_lon float8) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ft', case when s.lat is not null and p_lat is not null then round(_miles(s.lat, s.lon, p_lat, p_lon) * 5280)::int end,
    'radius', greatest(coalesce(s.geofence_radius_ft, 250), 1000),
    'known', s.lat is not null and p_lat is not null)
  from sites s where s.id = p_site
$$;

create or replace function _crew_row(c visit_crew) returns jsonb language sql stable as $$
  select jsonb_build_object('id', c.id, 'name', c.name, 'role', c.role, 'profile_id', c.profile_id,
    'arrived_at', c.arrived_at, 'arrived_by', c.arrived_by, 'arrived_ok', c.arrived_ok,
    'left_at', c.left_at, 'left_by', c.left_by, 'left_ok', c.left_ok,
    'verified', c.arrived_by = 'self' and c.arrived_ok and c.left_by = 'self' and c.left_ok)
$$;

-- For a helper's phone: calls of his company with someone on site now (to join), and where he's checked in
create or replace function crew_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'role', coalesce(m.crew_role, 'helper'),
    'mine', (select coalesce(jsonb_agg(_crew_row(c) || jsonb_build_object('work_order_id', w.id, 'number', w.number, 'site', s.name,
               'lead', (select full_name from profiles where id = v.technician_id)) order by c.arrived_at desc), '[]')
             from visit_crew c join visits v on v.id = c.visit_id join work_orders w on w.id = c.work_order_id join sites s on s.id = w.site_id
             where c.profile_id = m.id and c.left_at is null),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('visit_id', v.id, 'work_order_id', w.id, 'number', w.number, 'site', s.name,
               'address', s.address, 'lead', p.full_name, 'arrived_at', v.arrived_at, 'issue', w.issue_description) order by v.arrived_at desc), '[]')
             from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id join profiles p on p.id = v.technician_id
             where w.contractor_id = m.contractor_id and v.status = 'on_site' and v.arrived_at is not null and v.completed_at is null
               and v.technician_id <> m.id));
end $$;

create or replace function crew_check_in(p_visit uuid, p_lat float8, p_lon float8) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); v visits; w work_orders; g jsonb; ok boolean; c visit_crew;
begin
  select * into v from visits where id = p_visit;
  select * into w from work_orders where id = v.work_order_id;
  if v.id is null or m.contractor_id is distinct from w.contractor_id or not m.active then raise exception 'That isn''t one of your company''s calls.'; end if;
  if v.status <> 'on_site' or v.completed_at is not null then raise exception 'Nobody is checked in on that call right now.'; end if;
  if v.technician_id = m.id then raise exception 'You''re the lead on this call.'; end if;
  select * into c from visit_crew where profile_id = m.id and left_at is null;
  if c.id is not null then
    raise exception 'You''re still checked in on call #%. Check out there first ("Leaving").', (select number from work_orders where id = c.work_order_id);
  end if;
  if p_lat is null then raise exception 'Turn on location for this app, then tap "I''m here" again.'; end if;
  g := _crew_where(w.site_id, p_lat, p_lon);
  ok := not (g->>'known')::boolean or (g->>'ft')::int <= (g->>'radius')::int;
  if not ok then raise exception 'You''re about % ft from % (the area is % ft). Check in when you''re there.', g->>'ft', (select name from sites where id = w.site_id), g->>'radius'; end if;
  insert into visit_crew (visit_id, work_order_id, contractor_id, profile_id, name, role, arrived_at, arrived_by, arrived_ok, arrived_ft)
  values (v.id, w.id, w.contractor_id, m.id, m.full_name, coalesce(m.crew_role, 'helper'), now(), 'self', (g->>'known')::boolean, (g->>'ft')::int)
  returning * into c;
  return _crew_row(c) || jsonb_build_object('number', w.number);
end $$;

create or replace function crew_check_out(p_crew uuid, p_lat float8, p_lon float8) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); c visit_crew; g jsonb; ok boolean;
begin
  select * into c from visit_crew where id = p_crew and left_at is null;
  if c.id is null or c.profile_id is distinct from m.id then raise exception 'You''re not checked in there.'; end if;
  g := _crew_where((select site_id from work_orders where id = c.work_order_id), p_lat, p_lon);
  ok := p_lat is not null and (g->>'known')::boolean and (g->>'ft')::int <= (g->>'radius')::int;
  update visit_crew set left_at = now(), left_by = 'self', left_ok = ok, left_ft = (g->>'ft')::int where id = c.id returning * into c;
  return _crew_row(c) || jsonb_build_object('note', case when p_lat is null then 'No location: this check-out isn''t verified.'
    when not ok then format('You were about %s ft away, so this check-out isn''t verified.', g->>'ft') end);
end $$;

-- The lead (or the office) records someone arriving or leaving: for a person without the app, or one who forgot.
-- p_event: 'arrived' (p_name / p_role for someone without the app, or p_profile) or 'left' (p_crew); p_at: when (default now)
create or replace function crew_lead_mark(p_visit uuid, p_event text, p_crew uuid default null, p_name text default null,
  p_role text default 'helper', p_at timestamptz default null, p_profile uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v visits; w work_orders; c visit_crew; t timestamptz := least(now(), coalesce(p_at, now())); nm text;
begin
  select * into v from visits where id = p_visit;
  select * into w from work_orders where id = v.work_order_id;
  if v.id is null or (v.technician_id is distinct from auth.uid() and not is_contractor_office(w.contractor_id)) then raise exception 'Not your job.'; end if;
  if p_event = 'arrived' then
    if v.status <> 'on_site' then raise exception 'Tap "I''m here" first.'; end if;
    if p_profile is not null then
      if exists (select 1 from visit_crew where profile_id = p_profile and left_at is null) then raise exception 'They''re already checked in on a call.'; end if;
      select full_name into nm from profiles where id = p_profile and contractor_id = w.contractor_id and active;
      if nm is null then raise exception 'That person isn''t on your team.'; end if;
    else
      nm := nullif(trim(p_name), '');
      if nm is null then raise exception 'Enter their name.'; end if;
    end if;
    if coalesce(p_role, 'helper') not in ('helper', 'apprentice') then raise exception 'Pick helper or apprentice.'; end if;
    insert into visit_crew (visit_id, work_order_id, contractor_id, profile_id, name, role, arrived_at, arrived_by)
    values (v.id, w.id, w.contractor_id, p_profile, left(nm, 80), coalesce(p_role, 'helper'), greatest(t, v.arrived_at), 'lead') returning * into c;
  elsif p_event = 'left' then
    select * into c from visit_crew where id = p_crew and visit_id = p_visit and left_at is null;
    if c.id is null then raise exception 'They''re not checked in on this call.'; end if;
    update visit_crew set left_at = greatest(t, arrived_at), left_by = case when p_at is null then 'lead' else 'checkout' end
     where id = c.id returning * into c;
  else raise exception 'Unknown event.';
  end if;
  return _crew_row(c);
end $$;

-- The lead's view of the crew on his visit
create or replace function visit_crew_list(p_visit uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v visits; w work_orders;
begin
  select * into v from visits where id = p_visit;
  select * into w from work_orders where id = v.work_order_id;
  if v.id is null or not can_see_work_order(w.id) then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'crew', (select coalesce(jsonb_agg(_crew_row(c) order by c.arrived_at), '[]') from visit_crew c where c.visit_id = p_visit),
    'team', case when is_contractor_office(w.contractor_id) or v.technician_id = auth.uid() then
      (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name, 'role', coalesce(p.crew_role, 'helper')) order by p.full_name), '[]')
         from profiles p where p.contractor_id = w.contractor_id and p.active and p.is_technician and p.id <> v.technician_id
           and not exists (select 1 from visit_crew x where x.profile_id = p.id and x.left_at is null)) end);
end $$;

create or replace function set_crew_role(p_profile uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); n int;
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_dispatch) then raise exception 'Only your owner or dispatch can change this.'; end if;
  if p_role is not null and p_role not in ('helper', 'apprentice') then raise exception 'Pick helper or apprentice.'; end if;
  update profiles set crew_role = p_role where id = p_profile and contractor_id = m.contractor_id;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'That person isn''t on your team.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Leaving / finishing asks about anyone still checked in on the visit
create or replace function _crew_open(p_visit uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(_crew_row(c) order by c.arrived_at), '[]') from visit_crew c where c.visit_id = p_visit and c.left_at is null
$$;
select from _patch_fn('tech_leave(uuid,visit_outcome,text,timestamptz,double precision,double precision)'::regprocedure,
  'perform _on_site(v);',
  'perform _on_site(v);
  if exists (select 1 from visit_crew where visit_id = v.id and left_at is null) then
    return jsonb_build_object(''ok'', false, ''missing'', jsonb_build_array(jsonb_build_object(''item'', ''crew'', ''crew'', _crew_open(v.id),
      ''message'', (select string_agg(name, '', '') from visit_crew where visit_id = v.id and left_at is null) || '' still checked in here. Did they stay until now?'')));
  end if;');
select from _patch_fn('tech_finish_visit(uuid,visit_outcome,text,jsonb,timestamptz,double precision,double precision)'::regprocedure,
  't := greatest(t, v.arrived_at);',
  't := greatest(t, v.arrived_at);
  if exists (select 1 from visit_crew where visit_id = v.id and left_at is null) then
    return jsonb_build_object(''ok'', false, ''missing'', jsonb_build_array(jsonb_build_object(''item'', ''crew'', ''crew'', _crew_open(v.id),
      ''message'', (select string_agg(name, '', '') from visit_crew where visit_id = v.id and left_at is null) || '' still checked in here. Did they stay until now?'')));
  end if;');

-- ---------- verified time: helpers come from the crew's own check-ins ----------
create or replace function _verified(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; cc customer_contractors; r record; e timestamptz; arr jsonb := '[]';
  onsite int; travel int; tcount int; away int; away_ver int; bill int; hmin int; hver int; hbill int; amin int; seg record; t timestamptz; pm_reg boolean;
  amn int; aver int; crew jsonb; has_crew boolean;
  t_on int := 0; t_tr int := 0; t_trc int := 0; t_pr int := 0; t_prv int := 0; t_bill int := 0; t_h int := 0; t_hv int := 0; t_hb int := 0; t_after int := 0;
  t_am int := 0; t_av int := 0; inc int;
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
    has_crew := exists (select 1 from visit_crew c where c.visit_id = r.id);
    hmin := 0; hver := 0; amn := 0; aver := 0;
    if has_crew then
      -- each person's own time on this visit; verified = his own location-checked check-in and check-out
      -- (still on site while the visit is open counts until it closes)
      select coalesce(sum(m), 0), coalesce(sum(m) filter (where ver), 0),
             coalesce(sum(m) filter (where role = 'apprentice'), 0), coalesce(sum(m) filter (where role = 'apprentice' and ver), 0)
        into hmin, hver, amn, aver
        from (select c.role, greatest(0, ceil(extract(epoch from (least(coalesce(c.left_at, e), e) - greatest(c.arrived_at, r.arrived_at))) / 60))::int m,
                     (c.arrived_by = 'self' and c.arrived_ok and ((c.left_by = 'self' and c.left_ok) or (c.left_at is null and r.completed_at is null))) ver
                from visit_crew c where c.visit_id = r.id) q;
      crew := (select coalesce(jsonb_agg(_crew_row(c) || jsonb_build_object('min', greatest(0, ceil(extract(epoch from (least(coalesce(c.left_at, e), e) - greatest(c.arrived_at, r.arrived_at))) / 60))::int)
                order by c.arrived_at), '[]') from visit_crew c where c.visit_id = r.id);
    else
      -- the lead's headcount only: recorded, not verified
      for seg in select (x->>'at')::timestamptz at_, (x->>'helpers')::int n,
                        lead((x->>'at')::timestamptz) over (order by (x->>'at')::timestamptz) nxt
                   from jsonb_array_elements(r.crew_log) x loop
        hmin := hmin + seg.n * greatest(0, ceil(extract(epoch from (least(coalesce(seg.nxt, e), e) - greatest(seg.at_, r.arrived_at))) / 60))::int;
      end loop;
      crew := '[]';
    end if;
    hbill := case when hver > 0 then (ceil(hver::numeric / inc) * inc)::int else 0 end;
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
      'crew', crew, 'helper_min', hmin, 'helper_verified_min', hver, 'helper_unverified_min', hmin - hver,
      'apprentice_min', amn, 'apprentice_verified_min', aver, 'helper_billable_min', hbill, 'after_hours_min', amin);
    t_on := t_on + onsite; t_tr := t_tr + travel; t_trc := t_trc + tcount; t_pr := t_pr + away; t_prv := t_prv + (away - away_ver); t_bill := t_bill + bill;
    t_h := t_h + hmin; t_hv := t_hv + hver; t_hb := t_hb + hbill; t_after := t_after + amin; t_am := t_am + amn; t_av := t_av + aver;
  end loop;
  return jsonb_build_object('visits', arr, 'pays_travel', coalesce(cc.pays_travel, 'yes'), 'min_hours', cc.min_hours, 'increment_min', inc,
    'onsite_h', round(t_on / 60.0, 2), 'travel_h', round(t_tr / 60.0, 2), 'travel_counted_h', round(t_trc / 60.0, 2),
    'parts_run_h', round(t_pr / 60.0, 2), 'parts_run_unverified_h', round(t_prv / 60.0, 2),
    'verified_h', round((t_on + t_trc + t_pr) / 60.0, 2),
    'tech_billable_h', round(t_bill / 60.0, 2), 'helper_h', round(t_h / 60.0, 2), 'helper_billable_h', round(t_hb / 60.0, 2),
    'helper_verified_h', round(t_hv / 60.0, 2), 'helper_unverified_h', round((t_h - t_hv) / 60.0, 2),
    'apprentice_h', round(t_am / 60.0, 2), 'apprentice_verified_h', round(t_av / 60.0, 2),
    'billable_h', round((t_bill + t_hb) / 60.0, 2),
    'after_hours_h', round(t_after / 60.0, 2), 'regular_h', round(greatest(0, t_on - t_after) / 60.0, 2),
    'nte', w.nte, 'travel_area_mi', (select travel_area_miles from customers where id = w.customer_id));
end $$;

-- The written bill: helper and apprentice lines at their rates (overtime rates on after-hours calls). On a customer's
-- Time Verify call only verified crew hours go on; on your own customer's call, every recorded crew hour.
select from _patch_fn('_bill_auto_lines(uuid)'::regprocedure,
  'out jsonb := ''[]''; p record; a jsonb; ql jsonb;',
  'out jsonb := ''[]''; p record; a jsonb; ql jsonb; appr numeric;');
select from _patch_fn('_bill_auto_lines(uuid)'::regprocedure,
  'helper := coalesce((v->>''helper_billable_h'')::numeric, 0);',
  'helper := case when w.mode = ''verify'' then coalesce((v->>''helper_verified_h'')::numeric, 0) - coalesce((v->>''apprentice_verified_h'')::numeric, 0)
                 else coalesce((v->>''helper_h'')::numeric, 0) - coalesce((v->>''apprentice_h'')::numeric, 0) end;
  appr := case when w.mode = ''verify'' then coalesce((v->>''apprentice_verified_h'')::numeric, 0) else coalesce((v->>''apprentice_h'')::numeric, 0) end;');
select from _patch_fn('_bill_auto_lines(uuid)'::regprocedure,
  'if helper > 0 then out := out || (_bill_line(''helper'', ''Helper labor (crew confirmed on site)'', helper, ''hr'', (r->>''helper'')::numeric) || jsonb_build_object(''tax'', _line_tax_default(''labor'', a))); end if;',
  'if helper > 0 then out := out || (_bill_line(''helper'', case when w.mode = ''verify'' then ''Helper labor (checked in on site)'' else ''Helper labor'' end, helper, ''hr'',
       (r->>case when w.after_hours then ''helper_ot'' else ''helper'' end)::numeric) || jsonb_build_object(''tax'', _line_tax_default(''labor'', a))); end if;
  if appr > 0 then out := out || (_bill_line(''apprentice'', case when w.mode = ''verify'' then ''Apprentice labor (checked in on site)'' else ''Apprentice labor'' end, appr, ''hr'',
       (r->>case when w.after_hours then ''apprentice_ot'' else ''apprentice'' end)::numeric) || jsonb_build_object(''tax'', _line_tax_default(''labor'', a))); end if;');
-- crew labor (helpers, apprentices) counts toward the labor checked against verified hours
select from _patch_fn('_bill_summary(uuid)'::regprocedure,
  'x->>''kind'' in (''labor'', ''after_hours'', ''helper'')',
  'x->>''kind'' in (''labor'', ''after_hours'', ''helper'', ''apprentice'')');

grant execute on function crew_today(), crew_check_in(uuid, float8, float8), crew_check_out(uuid, float8, float8),
  crew_lead_mark(uuid, text, uuid, text, text, timestamptz, uuid), visit_crew_list(uuid), set_crew_role(uuid, text) to authenticated;
revoke execute on function crew_today(), crew_check_in(uuid, float8, float8), crew_check_out(uuid, float8, float8),
  crew_lead_mark(uuid, text, uuid, text, text, timestamptz, uuid), visit_crew_list(uuid), set_crew_role(uuid, text) from anon;
revoke execute on function _crew_open(uuid), _crew_where(uuid, float8, float8) from public, anon, authenticated;

-- Your rates' team list shows who works as a helper or apprentice
select from _patch_fn('my_rates()'::regprocedure,
  '''pay_rate'', tp.pay_rate) order by p.full_name)',
  '''pay_rate'', tp.pay_rate, ''crew_role'', p.crew_role) order by p.full_name)');
