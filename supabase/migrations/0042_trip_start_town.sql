-- Where a trip started, for checking billed travel.
-- When a tech taps "I'm going", the phone's location at that moment is already saved (gps_logs, event en_route).
-- The store now sees only the nearest TOWN to that point and the rough distance / drive time to the store,
-- never the exact spot or a map. The bill check uses it:
--   * trip started inside the customer's "already in the area" distance (default 10 miles, the customer can change it)
--     and the bill has more hours than verified → say so plainly (travel billed from the shop?)
--   * the drive took much longer than the distance should take → say so
-- Nothing new is collected: no tracking between calls, no route.

-- ---------- US towns (nearest-town lookup) ----------
-- One row per ZIP code centroid with its post-office town name. Loaded once from a public ZIP list (see _load_places).
create table if not exists places (
  id    int generated always as identity primary key,
  city  text not null,
  state text not null,
  lat   double precision not null,
  lon   double precision not null
);
create index if not exists places_lat_lon on places (lat, lon);
alter table places enable row level security;     -- no policies: read only through the functions below

-- Parse the "zipcodes" package's codes.js text into places. Run once by us; safe to re-run:
--   select net.http_get('https://cdn.jsdelivr.net/npm/zipcodes@8.0.0/lib/codes.js');   -- returns a request id
--   select _load_places((select content from net._http_response where id = <that id>));
create or replace function _load_places(p_body text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into places (city, state, lat, lon)
  select distinct on (m[3], m[4], round(m[1]::numeric, 2), round(m[2]::numeric, 2)) m[3], m[4], m[1]::float8, m[2]::float8
    from regexp_matches(p_body, '"latitude":(-?[0-9.]+),"longitude":(-?[0-9.]+),"city":"([^"]+)","state":"([A-Z]{2})","country":"US"', 'g') m
   where not exists (select 1 from places p where p.city = m[3] and p.state = m[4]
                       and abs(p.lat - m[1]::float8) < 0.005 and abs(p.lon - m[2]::float8) < 0.005);
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function _load_places(text) from public, anon, authenticated;

-- Straight-line miles between two points
create or replace function _miles(a_lat float8, a_lon float8, b_lat float8, b_lon float8) returns numeric
language sql immutable as $$
  select (3958.8 * 2 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2)
          + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lon - a_lon) / 2), 2))))::numeric
$$;

-- "Fisher, MN" for a point (nearest ZIP town within ~40 miles), or null
create or replace function _nearest_town(p_lat float8, p_lon float8) returns text
language sql stable security definer set search_path = public as $$
  select city || ', ' || state from places
   where lat between p_lat - 0.6 and p_lat + 0.6 and lon between p_lon - 0.9 and p_lon + 0.9
   order by power(lat - p_lat, 2) + power((lon - p_lon) * cos(radians(p_lat)), 2) limit 1
$$;
revoke execute on function _nearest_town(float8, float8) from public, anon, authenticated;

-- ---------- The customer's "already in the area" distance ----------
alter table customers add column if not exists travel_area_miles int not null default 10
  check (travel_area_miles between 1 and 100);

create or replace function set_travel_area(p_miles int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'company') then raise exception 'You don''t have permission to change company settings.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if p_miles is null or p_miles < 1 or p_miles > 100 then raise exception 'Pick a distance from 1 to 100 miles.'; end if;
  perform _allow_internal(true);
  update customers set travel_area_miles = p_miles where id = m.customer_id;
  perform _end_internal();
  return jsonb_build_object('ok', true, 'miles', p_miles);
end $$;
revoke execute on function set_travel_area(int) from public, anon;
grant execute on function set_travel_area(int) to authenticated;

-- ---------- One trip: town it started near, distance, expected vs actual drive ----------
create or replace function _trip(p_visit uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v visits; s sites; g gps_logs; area int; mi numeric; road int; expect int; drove int;
begin
  select * into v from visits where id = p_visit;
  if v.id is null or v.started_at is null then return null; end if;
  select st.* into s from sites st join work_orders w on w.site_id = st.id where w.id = v.work_order_id;
  select coalesce(c.travel_area_miles, 10) into area from customers c where c.id = s.customer_id;
  drove := case when v.arrived_at is not null then greatest(0, ceil(extract(epoch from (v.arrived_at - v.started_at)) / 60))::int end;
  select * into g from gps_logs where visit_id = p_visit and event = 'en_route' order by recorded_at limit 1;
  if g.id is null or s.lat is null then
    return jsonb_build_object('known', false, 'drive_min', drove, 'area_mi', area);
  end if;
  mi := _miles(g.lat, g.lon, s.lat, s.lon);
  road := round(mi * 1.25)::int;                              -- roads aren't straight
  expect := case when mi < 0.5 then 0 else round(mi * 1.25 / 50 * 60)::int + 3 end;   -- ~50 mph plus getting going
  return jsonb_build_object('known', true, 'town', _nearest_town(g.lat, g.lon), 'miles', road,
    'expected_min', expect, 'drive_min', drove, 'area_mi', area, 'in_area', road <= area,
    'slow', drove is not null and drove > round(expect * 1.25) + 10);
end $$;
revoke execute on function _trip(uuid) from public, anon, authenticated;

-- Verified time now carries each trip's start town (same as 0016 otherwise)
create or replace function _verified(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; cc customer_contractors; r record; e timestamptz; arr jsonb := '[]';
  onsite int; travel int; tcount int; away int; away_ver int; bill int;
  t_on int := 0; t_tr int := 0; t_trc int := 0; t_pr int := 0; t_prv int := 0; t_bill int := 0; inc int;
begin
  select * into w from work_orders where id = p_wo;
  cc := _cc(w.customer_id, w.contractor_id);
  inc := coalesce(cc.increment_min, 15);
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
    arr := arr || jsonb_build_object('visit_id', r.id, 'visit_no', r.visit_no, 'tech', r.tech, 'started_at', r.started_at,
      'arrived_at', r.arrived_at, 'left_at', r.completed_at, 'arrival_by_store', r.arrival_source = 'store',
      'checkin_verified', r.checkin_verified, 'outcome', r.outcome, 'open', r.completed_at is null,
      'onsite_min', onsite, 'travel_min', travel, 'travel_counted_min', tcount, 'parts_run_min', away,
      'parts_run_unverified_min', away - away_ver, 'billable_min', bill, 'trip', _trip(r.id));
    t_on := t_on + onsite; t_tr := t_tr + travel; t_trc := t_trc + tcount; t_pr := t_pr + away; t_prv := t_prv + (away - away_ver); t_bill := t_bill + bill;
  end loop;
  return jsonb_build_object('visits', arr, 'pays_travel', coalesce(cc.pays_travel, 'yes'), 'min_hours', cc.min_hours, 'increment_min', inc,
    'onsite_h', round(t_on / 60.0, 2), 'travel_h', round(t_tr / 60.0, 2), 'travel_counted_h', round(t_trc / 60.0, 2),
    'parts_run_h', round(t_pr / 60.0, 2), 'parts_run_unverified_h', round(t_prv / 60.0, 2),
    'verified_h', round((t_on + t_trc + t_pr) / 60.0, 2), 'billable_h', round(t_bill / 60.0, 2), 'nte', w.nte,
    'travel_area_mi', (select travel_area_miles from customers where id = w.customer_id));
end $$;

-- Bill check: adds plain-language travel notes
create or replace function _invoice_check(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb := _verified(p_wo); i call_invoices; explained numeric; unexpl numeric; nte numeric; notes jsonb := '[]'; x jsonb; t jsonb;
begin
  select * into i from call_invoices where work_order_id = p_wo;
  for x in select * from jsonb_array_elements(v->'visits') loop
    t := x->'trip';
    if t is null or not coalesce((t->>'known')::boolean, false) then continue; end if;
    if (t->>'slow')::boolean then
      notes := notes || to_jsonb(format('Visit %s: the drive took %s min. From near %s (about %s mi) it usually takes about %s.',
        x->>'visit_no', t->>'drive_min', coalesce(t->>'town', 'the start point'), t->>'miles', t->>'expected_min'));
    end if;
  end loop;
  if i.work_order_id is null then return v || jsonb_build_object('invoice', null, 'travel_notes', notes); end if;
  nte := (v->>'nte')::numeric;
  explained := (v->>'billable_h')::numeric + i.other_hours;
  unexpl := greatest(0, round(i.hours_billed - explained, 2));
  if unexpl > 0 then
    for x in select * from jsonb_array_elements(v->'visits') loop
      t := x->'trip';
      if t is not null and coalesce((t->>'in_area')::boolean, false) then
        notes := notes || to_jsonb(format('Visit %s: the trip started near %s, about %s mi from the store (inside your %s-mile area). Only the %s-min drive is counted. If the extra %s h is travel from the shop, it wasn''t driven.',
          x->>'visit_no', coalesce(t->>'town', 'the store'), t->>'miles', t->>'area_mi', t->>'drive_min', trim_scale(unexpl)));
      end if;
    end loop;
  end if;
  return v || jsonb_build_object('invoice', jsonb_build_object('number', i.invoice_number, 'total', i.total, 'status', i.status),
    'billed_h', i.hours_billed, 'other_h', i.other_hours, 'other_reason', i.other_reason,
    'explained_h', explained, 'unexplained_h', unexpl,
    'under_h', greatest(0, round((v->>'billable_h')::numeric - i.hours_billed, 2)),
    'over_nte', nte is not null and i.total > nte, 'over_nte_by', case when nte is not null and i.total > nte then i.total - nte end,
    'all_verified', unexpl = 0, 'travel_notes', notes);
end $$;
