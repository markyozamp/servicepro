-- The temperature log for a claim or an inspector: one location, any dates (up to 31 days), every unit or one.
-- Per unit: the limits, every reading (for the graph), hour by hour in the location's time zone (the hour's last reading,
-- its high and low, out of range or not), alarms (start, end, who acknowledged, service call), door openings per day,
-- typed entries (who). Anyone who can see the location's sensors can pull it.
create or replace function monitor_report(p_site uuid, p_from date, p_to date, p_device uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s sites; tz text; t0 timestamptz; t1 timestamptz;
begin
  select * into s from sites where id = p_site;
  if s.id is null or _monitor_role(p_site) is null then raise exception 'Not allowed.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Pick the dates.'; end if;
  if p_to - p_from > 31 then raise exception 'Up to 31 days at a time.'; end if;
  tz := coalesce(s.timezone, 'America/Chicago');
  t0 := (p_from::timestamp) at time zone tz;
  t1 := ((p_to + 1)::timestamp) at time zone tz;
  return jsonb_build_object(
    'site', jsonb_build_object('name', s.name, 'address', s.address), 'timezone', tz,
    'customer', (select name from customers where id = s.customer_id), 'from', p_from, 'to', p_to, 'made_at', now(),
    'units', (select coalesce(jsonb_agg(u order by u->>'name'), '[]') from (
      select jsonb_build_object(
        'id', d.id, 'name', d.name, 'kind', d.kind, 'low_f', d.low_f, 'high_f', d.high_f,
        'readings', (select coalesce(jsonb_agg(jsonb_build_object('at', r.at, 'temp_f', r.temp_f, 'door_open', r.door_open) order by r.at), '[]')
                     from (select * from monitor_readings where device_id = d.id and at >= t0 and at < t1 order by at limit 6000) r),
        'hours', (select coalesce(jsonb_agg(jsonb_build_object('hour', h.hr, 'last', h.last_f, 'low', h.lo, 'high', h.hi, 'n', h.n,
                    'out', (d.low_f is not null and h.lo < d.low_f) or (d.high_f is not null and h.hi > d.high_f)) order by h.hr), '[]')
                  from (select date_trunc('hour', r.at at time zone tz) hr, min(r.temp_f) lo, max(r.temp_f) hi, count(*) n,
                               (array_agg(r.temp_f order by r.at desc))[1] last_f
                          from monitor_readings r where r.device_id = d.id and r.at >= t0 and r.at < t1 and r.temp_f is not null
                         group by 1) h),
        'doors', case when d.kind = 'door' then (select coalesce(jsonb_agg(jsonb_build_object('day', x.day, 'opened', x.opened, 'longest_min', x.longest) order by x.day), '[]')
                  from (select (o.at at time zone tz)::date as day, count(*) opened,
                               round(max(extract(epoch from coalesce(o.closed_at, least(now(), t1)) - o.at)) / 60) longest
                          from (select r.at, (select min(c.at) from monitor_readings c where c.device_id = d.id and c.at > r.at and c.door_open = false) closed_at
                                  from (select at, door_open, lag(door_open) over (order by at) prev from monitor_readings
                                         where device_id = d.id and at >= t0 and at < t1 and door_open is not null) r
                                 where r.door_open and coalesce(r.prev, false) = false) o
                         group by 1) x) end,
        'alarms', (select coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'value', a.value, 'started_at', a.started_at, 'cleared_at', a.cleared_at,
                     'ack_at', a.ack_at, 'ack_name', (select full_name from profiles where id = a.ack_by),
                     'call_number', (select number from work_orders where id = a.work_order_id)) order by a.started_at), '[]')
                   from monitor_alarms a where a.device_id = d.id and a.started_at < t1 and coalesce(a.cleared_at, now()) >= t0),
        'typed', (select coalesce(jsonb_agg(jsonb_build_object('at', r.at, 'temp_f', r.temp_f, 'by', (select full_name from profiles where id = r.by_profile), 'note', r.note) order by r.at), '[]')
                  from monitor_readings r where r.device_id = d.id and r.source = 'typed' and r.at >= t0 and r.at < t1)) u
      from monitor_devices d
      where d.site_id = p_site and (p_device is null or d.id = p_device)
        and (d.removed_at is null or d.removed_at >= t0)) z(u)));
end $$;

grant execute on function monitor_report(uuid, date, date, uuid) to authenticated;
revoke execute on function monitor_report(uuid, date, date, uuid) from anon;
