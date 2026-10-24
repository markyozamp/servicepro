-- Temperature and door monitoring.
--  * A store location gets a gateway (the box that plugs into the router or runs on cellular). The gateway sends its
--    sensors' readings to its own private web address (/api/monitor/<token>), which lands in monitor_ingest.
--  * Sensors: temperature (walk-in, case, freezer) and door contacts (walk-in door), each tied to a unit if known.
--    Stores without sensors keep a typed log ('manual'): same limits, same alarms.
--  * Alarms: too warm / too cold for longer than the set minutes (opens a service call to the contractor, with the
--    readings, unless turned off or a call is already open for that unit), door open too long, a sensor or the
--    gateway gone quiet, battery low. Each goes to the store's alarm list and to the contractor's office (and whoever
--    is on call); a reminder if nobody acknowledges it in 30 minutes; a notice when it's back to normal.
--  * Sensors the gateway hears but nobody has set up yet are listed, so setup is picking from a list.

create table if not exists monitor_gateways (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references customers(id) on delete cascade,
  site_id      uuid not null references sites(id) on delete cascade,
  name         text not null,
  vendor       text not null default 'milesight' check (vendor in ('milesight', 'monnit', 'other')),
  token        uuid not null default gen_random_uuid() unique,
  last_seen_at timestamptz,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  removed_at   timestamptz
);
alter table monitor_gateways enable row level security;

create table if not exists monitor_devices (
  id              uuid primary key default gen_random_uuid(),
  customer_id     uuid not null references customers(id) on delete cascade,
  site_id         uuid not null references sites(id) on delete cascade,
  gateway_id      uuid references monitor_gateways(id),
  equipment_id    uuid references equipment(id) on delete set null,
  contractor_id   uuid references contractors(id),        -- alarms go to; null = the location's contractor
  kind            text not null check (kind in ('temp', 'door', 'manual')),
  name            text not null,
  external_id     text,                                     -- the sensor's ID (DevEUI / serial)
  low_f           numeric(6,1),
  high_f          numeric(6,1),
  alarm_after_min int not null default 30 check (alarm_after_min between 0 and 720),
  door_max_min    int not null default 10 check (door_max_min between 1 and 240),
  quiet_after_min int not null default 60 check (quiet_after_min between 15 and 1440),
  auto_call       boolean not null default true,
  issue_code      text,
  active          boolean not null default true,
  battery_pct     int,
  last_seen_at    timestamptz,
  last_temp_f     numeric(6,1),
  out_since       timestamptz,
  door_open       boolean,
  door_since      timestamptz,
  created_by      uuid,
  created_at      timestamptz not null default now(),
  removed_at      timestamptz
);
create unique index if not exists monitor_devices_ext on monitor_devices (lower(external_id)) where removed_at is null and external_id is not null;
create index if not exists monitor_devices_site on monitor_devices (site_id) where removed_at is null;
alter table monitor_devices enable row level security;

create table if not exists monitor_readings (
  id          bigserial primary key,
  device_id   uuid not null references monitor_devices(id) on delete cascade,
  at          timestamptz not null,
  temp_f      numeric(6,1),
  door_open   boolean,
  battery_pct int,
  source      text not null default 'sensor',               -- sensor / typed
  by_profile  uuid,
  note        text
);
create index if not exists monitor_readings_dev on monitor_readings (device_id, at desc);
alter table monitor_readings enable row level security;

create table if not exists monitor_alarms (
  id            uuid primary key default gen_random_uuid(),
  device_id     uuid references monitor_devices(id) on delete cascade,
  gateway_id    uuid references monitor_gateways(id) on delete cascade,
  customer_id   uuid not null,
  site_id       uuid not null,
  contractor_id uuid,
  kind          text not null check (kind in ('high', 'low', 'door', 'quiet', 'battery', 'gateway')),
  value         numeric,
  started_at    timestamptz not null default now(),
  cleared_at    timestamptz,
  ack_at        timestamptz,
  ack_by        uuid,
  reminded_at   timestamptz,
  work_order_id uuid,
  call_note     text
);
create unique index if not exists monitor_alarms_open_dev on monitor_alarms (device_id, kind) where cleared_at is null and device_id is not null;
create unique index if not exists monitor_alarms_open_gw on monitor_alarms (gateway_id, kind) where cleared_at is null and gateway_id is not null;
create index if not exists monitor_alarms_site on monitor_alarms (site_id, started_at desc);
alter table monitor_alarms enable row level security;

create table if not exists monitor_heard (             -- sensors the gateway hears that aren't set up yet
  gateway_id   uuid not null references monitor_gateways(id) on delete cascade,
  external_id  text not null,
  last_seen_at timestamptz not null default now(),
  sample       jsonb,
  primary key (gateway_id, external_id)
);
alter table monitor_heard enable row level security;

create table if not exists alarm_contacts (            -- the store's alarm list (all locations, or one)
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references customers(id) on delete cascade,
  profile_id  uuid not null references profiles(id) on delete cascade,
  site_id     uuid references sites(id) on delete cascade,
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);
create unique index if not exists alarm_contacts_one on alarm_contacts (profile_id, coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid));
alter table alarm_contacts enable row level security;

-- ---------- who may do what at a location ----------
-- 'store_admin' / 'store' (sees the location), 'office' (a contractor's office serving it), 'tech' (their tech), or null
create or replace function _monitor_role(p_site uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); s sites;
begin
  select * into s from sites where id = p_site;
  if m.id is null or s.id is null then return null; end if;
  if m.customer_id is not null then
    if m.customer_id = s.customer_id and profile_sees_site(m.id, s.id) then return case when m.is_org_admin then 'store_admin' else 'store' end; end if;
    return null;
  end if;
  if m.contractor_id is not null and exists (select 1 from customer_contractors cc where cc.contractor_id = m.contractor_id and cc.customer_id = s.customer_id
       and cc.store_removed_at is null and cc.contractor_removed_at is null) then
    if is_contractor_office(m.contractor_id) then return 'office'; end if;
    if m.is_technician then return 'tech'; end if;
  end if;
  return null;
end $$;

create or replace function _monitor_manage(p_site uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(_monitor_role(p_site), '') not in ('store_admin', 'office') then
    raise exception 'Only the store''s admin or its contractor''s office can set up sensors here.';
  end if;
end $$;

-- ---------- alarms ----------
create or replace function _alarm_label(a monitor_alarms) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select s.name from sites s where s.id = a.site_id), 'Location') || ' · ' ||
         coalesce((select d.name from monitor_devices d where d.id = a.device_id), (select 'gateway ' || g.name from monitor_gateways g where g.id = a.gateway_id), 'sensor')
$$;

create or replace function _alarm_notify(p_alarm uuid, p_what text) returns void       -- p_what: open / remind / clear
language plpgsql security definer set search_path = public as $$
declare a monitor_alarms; d monitor_devices; g monitor_gateways; lbl text; msg text; wno int; con text; tz text; mins int;
begin
  select * into a from monitor_alarms where id = p_alarm;
  select * into d from monitor_devices where id = a.device_id;
  select * into g from monitor_gateways where id = coalesce(a.gateway_id, d.gateway_id);
  lbl := _alarm_label(a);
  tz := coalesce((select timezone from sites where id = a.site_id), 'America/Chicago');
  wno := (select number from work_orders where id = a.work_order_id);
  con := (select name from contractors where id = a.contractor_id);
  mins := greatest(0, round(extract(epoch from now() - coalesce(case when a.kind = 'door' then d.door_since end, d.out_since, a.started_at)) / 60))::int;
  if p_what = 'clear' then
    msg := case a.kind
      when 'high' then format('Back to normal: %s is %s°F.', lbl, trim_scale(d.last_temp_f))
      when 'low' then format('Back to normal: %s is %s°F.', lbl, trim_scale(d.last_temp_f))
      when 'door' then format('Closed: %s door is shut again.', lbl)
      when 'quiet' then format('%s: the sensor is reporting again.', lbl)
      when 'battery' then format('%s: new battery, %s%%.', lbl, d.battery_pct)
      else format('The %s is online again; its sensors are reporting.', lbl) end;
  else
    msg := case a.kind
      when 'high' then format('ALARM: %s is %s°F, above %s°F for %s min.', lbl, trim_scale(d.last_temp_f), trim_scale(d.high_f), mins)
      when 'low' then format('ALARM: %s is %s°F, below %s°F for %s min.', lbl, trim_scale(d.last_temp_f), trim_scale(d.low_f), mins)
      when 'door' then format('ALARM: %s door has been open %s min.', lbl, mins)
      when 'quiet' then format('%s: the sensor has stopped reporting (last heard %s). Check that it''s in place and has battery.', lbl,
                              coalesce(to_char(d.last_seen_at at time zone tz, 'FMHH12:MI AM Mon DD'), 'never'))
      when 'battery' then format('%s: sensor battery low (%s%%). Replace with lithium batteries.', lbl, d.battery_pct)
      else format('The %s is offline (last heard %s), so its sensors can''t report. Check its power and internet.', lbl,
                  coalesce(to_char(g.last_seen_at at time zone tz, 'FMHH12:MI AM Mon DD'), 'never')) end
      || case when wno is not null then format(' Service call #%s is open with %s.', wno, coalesce(con, 'the contractor')) else '' end
      || case when p_what = 'remind' then ' Nobody has acknowledged it yet.' else '' end;
  end if;
  -- the store's alarm list (if they have none: whoever opens calls there)
  perform _notify(p.id, a.work_order_id, 'alarm', msg, format('alarm:%s:%s', a.id, p_what))
    from profiles p where p.customer_id = a.customer_id and p.active and profile_sees_site(p.id, a.site_id)
     and (exists (select 1 from alarm_contacts c where c.profile_id = p.id and c.active and (c.site_id is null or c.site_id = a.site_id))
          or (not exists (select 1 from alarm_contacts c join profiles q on q.id = c.profile_id and q.active
                           where c.customer_id = a.customer_id and c.active and (c.site_id is null or c.site_id = a.site_id))
              and (p.is_org_admin or p.can_open_calls)));
  -- the contractor's office, and whoever is on call
  if a.contractor_id is not null then
    perform _notify(p.id, a.work_order_id, 'alarm', msg, format('alarm:%s:%s', a.id, p_what))
      from profiles p where p.contractor_id = a.contractor_id and p.active and (p.is_org_admin or p.can_dispatch);
    perform _notify(_oncall_now(a.contractor_id), a.work_order_id, 'alarm', msg, format('alarm:%s:%s', a.id, p_what));
  end if;
end $$;

create or replace function _alarm_clear(p_dev uuid, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare id_ uuid;
begin
  update monitor_alarms set cleared_at = now() where device_id = p_dev and kind = p_kind and cleared_at is null returning id into id_;
  if id_ is not null then perform _alarm_notify(id_, 'clear'); end if;
end $$;

create or replace function _alarm_open(p_dev uuid, p_kind text, p_value numeric) returns uuid
language plpgsql security definer set search_path = public as $$
declare d monitor_devices; s sites; a monitor_alarms; it issue_types; v_con uuid; w work_orders; open_w uuid; note text; hist text;
begin
  select * into d from monitor_devices where id = p_dev;
  if exists (select 1 from monitor_alarms where device_id = p_dev and kind = p_kind and cleared_at is null) then return null; end if;
  select * into s from sites where id = d.site_id;
  select * into it from issue_types where active and code = coalesce(d.issue_code,
    case when d.name ~* 'freez' then 'wi_freezer_down' when d.name ~* 'case' then 'case_warm' else 'wi_cooler_down' end);
  v_con := coalesce(d.contractor_id, _route_contractor(d.site_id, it.trade_id), _route_contractor(d.site_id, null));
  insert into monitor_alarms (device_id, customer_id, site_id, contractor_id, kind, value)
  values (d.id, d.customer_id, d.site_id, v_con, p_kind, p_value) returning * into a;
  if p_kind in ('high', 'low') and d.auto_call and v_con is not null then
    -- a call already open for this unit takes the alarm instead of a second call
    select w2.id into open_w from work_orders w2
     where w2.site_id = d.site_id and w2.status not in ('completed', 'invoiced', 'cancelled')
       and ((d.equipment_id is not null and w2.equipment_id = d.equipment_id)
            or exists (select 1 from monitor_alarms x where x.work_order_id = w2.id and x.device_id = d.id))
     order by w2.created_at desc limit 1;
    if open_w is null then
      select string_agg(format('%s %s°F', to_char(r.at at time zone s.timezone, 'FMHH12:MI AM'), trim_scale(r.temp_f)), ', ' order by r.at)
        into hist from (select * from monitor_readings where device_id = d.id and temp_f is not null order by at desc limit 6) r;
      begin
        w := _create_call(d.site_id, it.id,
               format('Temperature alarm: %s is %s°F (set %s to %s°F), out of range since %s. Last readings: %s.', d.name, trim_scale(d.last_temp_f),
                      coalesce(trim_scale(d.low_f)::text, 'any'), coalesce(trim_scale(d.high_f)::text, 'any'),
                      to_char(coalesce(d.out_since, now()) at time zone s.timezone, 'FMHH12:MI AM'), coalesce(hist, 'none')),
               d.equipment_id, null, null, 'service', v_con, null, null, null, 'store', null, 'Temperature alarm');
        open_w := w.id;
      exception when others then note := left(sqlerrm, 300);
      end;
    else note := 'A call was already open for this unit.';
    end if;
    update monitor_alarms set work_order_id = open_w, call_note = note where id = a.id;
  end if;
  perform _alarm_notify(a.id, 'open');
  return a.id;
end $$;

-- Check one sensor against its limits now
create or replace function _monitor_eval(p_dev uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d monitor_devices; g monitor_gateways; quiet boolean; gw_down boolean;
begin
  select * into d from monitor_devices where id = p_dev;
  if d.id is null or d.removed_at is not null or not d.active then return; end if;
  if d.kind in ('temp', 'manual') then
    if d.out_since is not null and now() - d.out_since >= make_interval(mins => case when d.kind = 'manual' then 0 else d.alarm_after_min end) then
      if d.high_f is not null and d.last_temp_f > d.high_f then perform _alarm_clear(d.id, 'low'); perform _alarm_open(d.id, 'high', d.last_temp_f);
      elsif d.low_f is not null and d.last_temp_f < d.low_f then perform _alarm_clear(d.id, 'high'); perform _alarm_open(d.id, 'low', d.last_temp_f);
      end if;
    elsif d.out_since is null then
      perform _alarm_clear(d.id, 'high'); perform _alarm_clear(d.id, 'low');
    end if;
  end if;
  if d.kind = 'door' then
    if coalesce(d.door_open, false) and d.door_since is not null and now() - d.door_since >= make_interval(mins => d.door_max_min) then
      perform _alarm_open(d.id, 'door', round(extract(epoch from now() - d.door_since) / 60));
    elsif not coalesce(d.door_open, false) then perform _alarm_clear(d.id, 'door');
    end if;
  end if;
  if d.kind <> 'manual' then
    select * into g from monitor_gateways where id = d.gateway_id and removed_at is null;
    gw_down := g.id is not null and coalesce(g.last_seen_at, g.created_at) < now() - interval '30 minutes';
    quiet := coalesce(d.last_seen_at, d.created_at) < now() - make_interval(mins => d.quiet_after_min);
    if quiet and not gw_down then perform _alarm_open(d.id, 'quiet', null);
    elsif not quiet then perform _alarm_clear(d.id, 'quiet');
    end if;
    if d.battery_pct is not null and d.battery_pct <= 15 then perform _alarm_open(d.id, 'battery', d.battery_pct);
    elsif d.battery_pct is not null and d.battery_pct >= 30 then perform _alarm_clear(d.id, 'battery');
    end if;
  end if;
end $$;

create or replace function _gateway_eval(p_gw uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g monitor_gateways; a uuid;
begin
  select * into g from monitor_gateways where id = p_gw;
  if g.id is null or g.removed_at is not null then return; end if;
  if coalesce(g.last_seen_at, g.created_at) < now() - interval '30 minutes'
     and exists (select 1 from monitor_devices where gateway_id = g.id and removed_at is null and active) then
    if not exists (select 1 from monitor_alarms where gateway_id = g.id and kind = 'gateway' and cleared_at is null) then
      insert into monitor_alarms (gateway_id, customer_id, site_id, contractor_id, kind)
      values (g.id, g.customer_id, g.site_id, _route_contractor(g.site_id, null), 'gateway') returning id into a;
      perform _alarm_notify(a, 'open');
    end if;
  elsif coalesce(g.last_seen_at, g.created_at) >= now() - interval '30 minutes' then
    update monitor_alarms set cleared_at = now() where gateway_id = g.id and kind = 'gateway' and cleared_at is null returning id into a;
    if a is not null then perform _alarm_notify(a, 'clear'); end if;
  end if;
end $$;

-- A reading (from a sensor or typed in)
create or replace function _monitor_record(p_dev uuid, p_at timestamptz, p_temp_f numeric, p_door boolean, p_battery int, p_source text, p_by uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare d monitor_devices;
begin
  select * into d from monitor_devices where id = p_dev for update;
  insert into monitor_readings (device_id, at, temp_f, door_open, battery_pct, source, by_profile, note)
  values (p_dev, p_at, p_temp_f, p_door, p_battery, p_source, p_by, p_note);
  if p_at < coalesce(d.last_seen_at, '-infinity'::timestamptz) - interval '1 minute' then return; end if;   -- a late (buffered) reading: history only
  update monitor_devices set
    last_seen_at = greatest(coalesce(last_seen_at, p_at), p_at),
    last_temp_f = coalesce(p_temp_f, last_temp_f),
    battery_pct = coalesce(p_battery, battery_pct),
    out_since = case when p_temp_f is null then out_since
                     when (low_f is not null and p_temp_f < low_f) or (high_f is not null and p_temp_f > high_f) then coalesce(out_since, p_at)
                     else null end,
    door_since = case when p_door is null then door_since when p_door and not coalesce(door_open, false) then p_at when p_door then door_since end,
    door_open = coalesce(p_door, door_open)
   where id = p_dev;
  perform _monitor_eval(p_dev);
end $$;

-- ---------- the gateway's door in (no login: its private token) ----------
-- p_readings: [{ id: sensor ID, at?, temp_f? | temp_c?, door_open?, battery? }] (the web route translates each brand)
create or replace function monitor_ingest(p_token uuid, p_readings jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g monitor_gateways; r jsonb; d monitor_devices; n int := 0; unknown int := 0; bad int := 0; at_ timestamptz; tf numeric; dr boolean; bt int;
begin
  select * into g from monitor_gateways where token = p_token and removed_at is null;
  if g.id is null then raise exception 'Unknown gateway.'; end if;
  if jsonb_typeof(p_readings) <> 'array' or jsonb_array_length(p_readings) > 200 then raise exception 'Send up to 200 readings at a time.'; end if;
  update monitor_gateways set last_seen_at = now() where id = g.id;
  for r in select * from jsonb_array_elements(p_readings) loop
    begin
      if coalesce(trim(r->>'id'), '') = '' then bad := bad + 1; continue; end if;
      select * into d from monitor_devices where lower(external_id) = lower(trim(r->>'id')) and site_id = g.site_id and removed_at is null and kind <> 'manual';
      if d.id is null then
        unknown := unknown + 1;
        insert into monitor_heard (gateway_id, external_id, last_seen_at, sample) values (g.id, left(trim(r->>'id'), 64), now(), r)
        on conflict (gateway_id, external_id) do update set last_seen_at = now(), sample = excluded.sample;
        continue;
      end if;
      if d.gateway_id is distinct from g.id then update monitor_devices set gateway_id = g.id where id = d.id; end if;
      at_ := least(now(), coalesce(nullif(r->>'at', '')::timestamptz, now()));
      tf := round(coalesce(nullif(r->>'temp_f', '')::numeric, nullif(r->>'temp_c', '')::numeric * 9 / 5 + 32), 1);
      if tf is not null and (tf < -150 or tf > 400) then tf := null; end if;
      dr := case when r->>'door_open' in ('true', 'false') then (r->>'door_open')::boolean end;
      bt := greatest(0, least(100, round(nullif(r->>'battery', '')::numeric)))::int;
      perform _monitor_record(d.id, at_, tf, dr, bt, 'sensor', null);
      n := n + 1;
    exception when others then bad := bad + 1;
    end;
  end loop;
  perform _gateway_eval(g.id);
  return jsonb_build_object('ok', true, 'recorded', n, 'not_set_up', unknown, 'skipped', bad);
end $$;

-- Every 2 minutes: door open too long, sensors or gateways gone quiet, out of range long enough, reminders
create or replace function monitor_watch() returns int
language plpgsql security definer set search_path = public as $$
declare d record; g record; a record; n int := 0;
begin
  for d in select md.id from monitor_devices md join customers cu on cu.id = md.customer_id
            where md.removed_at is null and md.active and (cu.name not like '%(demo)' or current_setting('app.watch_demo', true) = 'on') loop
    perform _monitor_eval(d.id); n := n + 1;
  end loop;
  for g in select mg.id from monitor_gateways mg join customers cu on cu.id = mg.customer_id
            where mg.removed_at is null and (cu.name not like '%(demo)' or current_setting('app.watch_demo', true) = 'on') loop
    perform _gateway_eval(g.id);
  end loop;
  for a in select id from monitor_alarms where cleared_at is null and ack_at is null and reminded_at is null
             and kind in ('high', 'low', 'door', 'gateway') and started_at < now() - interval '30 minutes' loop
    update monitor_alarms set reminded_at = now() where id = a.id;
    perform _alarm_notify(a.id, 'remind');
  end loop;
  return n;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-monitor', '*/2 * * * *', 'select public.monitor_watch()');
  end if;
end $$;

-- ---------- screens ----------
create or replace function _monitor_sites() returns setof uuid
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is not null then
    return query select s.id from sites s where s.customer_id = m.customer_id and profile_sees_site(m.id, s.id);
  elsif m.contractor_id is not null and (is_contractor_office(m.contractor_id) or m.is_technician) then
    return query select s.id from sites s join customer_contractors cc on cc.customer_id = s.customer_id
      where cc.contractor_id = m.contractor_id and cc.store_removed_at is null and cc.contractor_removed_at is null;
  end if;
end $$;

create or replace function monitor_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); office boolean; admin boolean;
begin
  if m.id is null then raise exception 'Not signed in.'; end if;
  office := m.contractor_id is not null and is_contractor_office(m.contractor_id);
  admin := m.customer_id is not null and m.is_org_admin;
  return jsonb_build_object(
    'can_manage', office or admin, 'side', case when m.customer_id is not null then 'store' else 'contractor' end,
    'devices', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'site_id', d.site_id, 'site', s.name, 'customer', cu.name,
        'kind', d.kind, 'name', d.name, 'external_id', d.external_id, 'equipment_id', d.equipment_id, 'contractor_id', d.contractor_id,
        'low_f', d.low_f, 'high_f', d.high_f, 'alarm_after_min', d.alarm_after_min, 'door_max_min', d.door_max_min,
        'quiet_after_min', d.quiet_after_min, 'auto_call', d.auto_call, 'issue_code', d.issue_code, 'active', d.active,
        'battery_pct', d.battery_pct, 'last_seen_at', d.last_seen_at, 'last_temp_f', d.last_temp_f, 'door_open', d.door_open,
        'door_since', d.door_since, 'out_since', d.out_since, 'gateway_id', d.gateway_id,
        'alarms', (select coalesce(jsonb_agg(a.kind), '[]') from monitor_alarms a where a.device_id = d.id and a.cleared_at is null))
        order by cu.name, s.name, d.name), '[]')
      from monitor_devices d join sites s on s.id = d.site_id join customers cu on cu.id = d.customer_id
      where d.removed_at is null and d.site_id in (select _monitor_sites())),
    'alarms', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'kind', a.kind, 'value', a.value, 'site_id', a.site_id, 'label', _alarm_label(a),
        'device_id', a.device_id, 'started_at', a.started_at, 'cleared_at', a.cleared_at, 'ack_at', a.ack_at,
        'ack_name', (select full_name from profiles where id = a.ack_by), 'work_order_id', a.work_order_id,
        'call_number', (select number from work_orders where id = a.work_order_id), 'call_note', a.call_note)
        order by a.cleared_at is not null, a.started_at desc), '[]')
      from monitor_alarms a where a.site_id in (select _monitor_sites()) and (a.cleared_at is null or a.cleared_at > now() - interval '7 days')),
    'gateways', case when office or admin then (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'site_id', g.site_id, 'site', s.name, 'name', g.name,
        'vendor', g.vendor, 'token', g.token, 'last_seen_at', g.last_seen_at,
        'heard', (select coalesce(jsonb_agg(jsonb_build_object('id', h.external_id, 'last_seen_at', h.last_seen_at, 'sample', h.sample) order by h.last_seen_at desc), '[]')
                  from monitor_heard h where h.gateway_id = g.id and h.last_seen_at > now() - interval '7 days'
                    and not exists (select 1 from monitor_devices x where lower(x.external_id) = lower(h.external_id) and x.removed_at is null)))
        order by s.name, g.name), '[]')
      from monitor_gateways g join sites s on s.id = g.site_id where g.removed_at is null and g.site_id in (select _monitor_sites())) else '[]'::jsonb end,
    'contacts', case when admin then (select coalesce(jsonb_agg(jsonb_build_object('profile_id', p.id, 'name', p.full_name, 'title', p.title,
        'all', exists (select 1 from alarm_contacts c where c.profile_id = p.id and c.site_id is null and c.active),
        'sites', (select coalesce(jsonb_agg(c.site_id), '[]') from alarm_contacts c where c.profile_id = p.id and c.site_id is not null and c.active))
        order by p.full_name), '[]')
      from profiles p where p.customer_id = m.customer_id and p.active) else null end);
end $$;

create or replace function monitor_history(p_device uuid, p_hours int default 48) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d monitor_devices;
begin
  select * into d from monitor_devices where id = p_device and removed_at is null;
  if d.id is null or _monitor_role(d.site_id) is null then raise exception 'Not allowed.'; end if;
  return jsonb_build_object('device', jsonb_build_object('id', d.id, 'name', d.name, 'kind', d.kind, 'low_f', d.low_f, 'high_f', d.high_f),
    'readings', (select coalesce(jsonb_agg(jsonb_build_object('at', r.at, 'temp_f', r.temp_f, 'door_open', r.door_open, 'battery', r.battery_pct,
        'source', r.source, 'by', (select full_name from profiles where id = r.by_profile), 'note', r.note) order by r.at), '[]')
      from monitor_readings r where r.device_id = d.id and r.at > now() - make_interval(hours => least(greatest(coalesce(p_hours, 48), 1), 24 * 31))));
end $$;

create or replace function save_gateway(p_id uuid, p_site uuid, p_name text, p_vendor text default 'milesight') returns jsonb
language plpgsql security definer set search_path = public as $$
declare g monitor_gateways; s sites;
begin
  select * into s from sites where id = p_site;
  perform _monitor_manage(p_site);
  if coalesce(trim(p_name), '') = '' then raise exception 'Name the gateway (e.g. Back office).'; end if;
  if coalesce(p_vendor, 'milesight') not in ('milesight', 'monnit', 'other') then raise exception 'Unknown gateway brand.'; end if;
  if p_id is null then
    insert into monitor_gateways (customer_id, site_id, name, vendor, created_by) values (s.customer_id, s.id, trim(p_name), coalesce(p_vendor, 'milesight'), auth.uid())
    returning * into g;
  else
    update monitor_gateways set name = trim(p_name), vendor = coalesce(p_vendor, vendor) where id = p_id and site_id = p_site and removed_at is null returning * into g;
    if g.id is null then raise exception 'That gateway isn''t here.'; end if;
  end if;
  return to_jsonb(g);
end $$;

create or replace function remove_gateway(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g monitor_gateways;
begin
  select * into g from monitor_gateways where id = p_id and removed_at is null;
  if g.id is null then raise exception 'That gateway isn''t here.'; end if;
  perform _monitor_manage(g.site_id);
  update monitor_gateways set removed_at = now() where id = g.id;
  update monitor_alarms set cleared_at = now() where gateway_id = g.id and cleared_at is null;
  return jsonb_build_object('ok', true);
end $$;

create or replace function save_monitor_device(p_id uuid, p_site uuid, p_kind text, p_name text, p_external_id text default null,
  p_low_f numeric default null, p_high_f numeric default null, p_alarm_after_min int default 30, p_door_max_min int default 10,
  p_quiet_after_min int default 60, p_auto_call boolean default true, p_equipment uuid default null, p_issue_code text default null,
  p_contractor uuid default null, p_active boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites; d monitor_devices; ext text := nullif(trim(p_external_id), '');
begin
  select * into s from sites where id = p_site;
  perform _monitor_manage(p_site);
  if p_kind not in ('temp', 'door', 'manual') then raise exception 'Pick temperature, door, or typed log.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Name it (e.g. Walk-in freezer).'; end if;
  if p_kind <> 'manual' and ext is null then raise exception 'Enter the sensor''s ID (printed on it, or pick it from the sensors the gateway hears).'; end if;
  if p_kind = 'manual' then ext := null; end if;
  if p_kind in ('temp', 'manual') and p_low_f is null and p_high_f is null then raise exception 'Set the low or high limit (°F).'; end if;
  if p_low_f is not null and p_high_f is not null and p_low_f >= p_high_f then raise exception 'The low limit has to be below the high limit.'; end if;
  if p_equipment is not null and not exists (select 1 from equipment where id = p_equipment and site_id = p_site) then raise exception 'That unit isn''t at this location.'; end if;
  if p_contractor is not null and not exists (select 1 from customer_contractors where contractor_id = p_contractor and customer_id = s.customer_id) then
    raise exception 'That contractor doesn''t serve this location.';
  end if;
  if p_issue_code is not null and not exists (select 1 from issue_types where code = p_issue_code and active) then raise exception 'Unknown problem type.'; end if;
  if ext is not null and exists (select 1 from monitor_devices where lower(external_id) = lower(ext) and removed_at is null and id is distinct from p_id) then
    raise exception 'That sensor is already set up.';
  end if;
  if p_id is null then
    insert into monitor_devices (customer_id, site_id, kind, name, external_id, low_f, high_f, alarm_after_min, door_max_min, quiet_after_min,
                                 auto_call, equipment_id, issue_code, contractor_id, active, created_by)
    values (s.customer_id, s.id, p_kind, trim(p_name), ext, p_low_f, p_high_f, coalesce(p_alarm_after_min, 30), coalesce(p_door_max_min, 10),
            coalesce(p_quiet_after_min, 60), coalesce(p_auto_call, true), p_equipment, p_issue_code, p_contractor, coalesce(p_active, true), auth.uid())
    returning * into d;
  else
    update monitor_devices set kind = p_kind, name = trim(p_name), external_id = ext, low_f = p_low_f, high_f = p_high_f,
           alarm_after_min = coalesce(p_alarm_after_min, alarm_after_min), door_max_min = coalesce(p_door_max_min, door_max_min),
           quiet_after_min = coalesce(p_quiet_after_min, quiet_after_min), auto_call = coalesce(p_auto_call, auto_call), equipment_id = p_equipment,
           issue_code = p_issue_code, contractor_id = p_contractor, active = coalesce(p_active, active),
           out_since = case when last_temp_f is not null and ((p_low_f is not null and last_temp_f < p_low_f) or (p_high_f is not null and last_temp_f > p_high_f))
                            then coalesce(out_since, now()) end
     where id = p_id and site_id = p_site and removed_at is null returning * into d;
    if d.id is null then raise exception 'That sensor isn''t here.'; end if;
    if not d.active then update monitor_alarms set cleared_at = now() where device_id = d.id and cleared_at is null; end if;
  end if;
  return to_jsonb(d);
end $$;

create or replace function remove_monitor_device(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d monitor_devices;
begin
  select * into d from monitor_devices where id = p_id and removed_at is null;
  if d.id is null then raise exception 'That sensor isn''t here.'; end if;
  perform _monitor_manage(d.site_id);
  update monitor_devices set removed_at = now() where id = d.id;
  update monitor_alarms set cleared_at = now() where device_id = d.id and cleared_at is null;
  return jsonb_build_object('ok', true);
end $$;

-- Typed reading (stores without sensors, or a check by hand)
create or replace function log_temperature(p_device uuid, p_temp_f numeric, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d monitor_devices;
begin
  select * into d from monitor_devices where id = p_device and removed_at is null;
  if d.id is null or _monitor_role(d.site_id) is null then raise exception 'Not allowed.'; end if;
  if d.kind = 'door' then raise exception 'That''s a door sensor.'; end if;
  if p_temp_f is null or p_temp_f < -60 or p_temp_f > 200 then raise exception 'Enter the temperature in °F.'; end if;
  perform _monitor_record(d.id, now(), round(p_temp_f, 1), null, null, 'typed', auth.uid(), nullif(trim(p_note), ''));
  return jsonb_build_object('ok', true, 'alarm', exists (select 1 from monitor_alarms where device_id = d.id and cleared_at is null and kind in ('high', 'low')));
end $$;

create or replace function ack_alarm(p_alarm uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a monitor_alarms;
begin
  select * into a from monitor_alarms where id = p_alarm;
  if a.id is null or _monitor_role(a.site_id) is null then raise exception 'Not allowed.'; end if;
  update monitor_alarms set ack_at = coalesce(ack_at, now()), ack_by = coalesce(ack_by, auth.uid()) where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

-- The store's admin picks who gets alarms (all locations, or one)
create or replace function set_alarm_contact(p_profile uuid, p_site uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not m.is_org_admin then raise exception 'Only your admin picks who gets alarms.'; end if;
  if not exists (select 1 from profiles where id = p_profile and customer_id = m.customer_id) then raise exception 'That person isn''t on your team.'; end if;
  if p_site is not null and not exists (select 1 from sites where id = p_site and customer_id = m.customer_id) then raise exception 'That location isn''t yours.'; end if;
  insert into alarm_contacts (customer_id, profile_id, site_id, active) values (m.customer_id, p_profile, p_site, coalesce(p_on, true))
  on conflict (profile_id, coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid)) do update set active = excluded.active, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

grant execute on function monitor_ingest(uuid, jsonb) to anon, authenticated;
grant execute on function monitor_overview(), monitor_history(uuid, int), save_gateway(uuid, uuid, text, text), remove_gateway(uuid),
  save_monitor_device(uuid, uuid, text, text, text, numeric, numeric, int, int, int, boolean, uuid, text, uuid, boolean), remove_monitor_device(uuid),
  log_temperature(uuid, numeric, text), ack_alarm(uuid), set_alarm_contact(uuid, uuid, boolean) to authenticated;
revoke execute on function monitor_overview(), monitor_history(uuid, int), save_gateway(uuid, uuid, text, text), remove_gateway(uuid),
  save_monitor_device(uuid, uuid, text, text, text, numeric, numeric, int, int, int, boolean, uuid, text, uuid, boolean), remove_monitor_device(uuid),
  log_temperature(uuid, numeric, text), ack_alarm(uuid), set_alarm_contact(uuid, uuid, boolean) from anon;
revoke execute on function monitor_watch(), _monitor_record(uuid, timestamptz, numeric, boolean, int, text, uuid, text), _monitor_eval(uuid), _gateway_eval(uuid),
  _alarm_open(uuid, text, numeric), _alarm_clear(uuid, text), _alarm_notify(uuid, text), _monitor_role(uuid), _monitor_manage(uuid), _monitor_sites()
  from public, anon, authenticated;
