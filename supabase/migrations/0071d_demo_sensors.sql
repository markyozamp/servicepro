-- The demo's sensors keep reporting (mid-range readings every 10 minutes), so the demo looks alive.
-- Demo alarms are only made on purpose (typing a reading out of range on a typed log).
create or replace function _demo_sensor_feed() returns int
language plpgsql security definer set search_path = public as $$
declare d record; n int := 0;
begin
  if current_setting('app.demo_feed', true) = 'off' then return 0; end if;   -- (tests)
  for d in select md.* from monitor_devices md join customers cu on cu.id = md.customer_id
            where cu.name like '%(demo)' and md.removed_at is null and md.active and md.kind in ('temp', 'door')
              and coalesce(md.last_seen_at, '-infinity'::timestamptz) < now() - interval '10 minutes' loop
    if d.kind = 'temp' then
      perform _monitor_record(d.id, now(), round((coalesce(d.low_f, d.high_f - 8) + coalesce(d.high_f, d.low_f + 8)) / 2 + (random() * 3 - 1.5)::numeric, 1), null, 87, 'sensor', null);
    else
      perform _monitor_record(d.id, now(), null, false, 91, 'sensor', null);
    end if;
    update monitor_gateways set last_seen_at = now() where id = d.gateway_id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function _demo_sensor_feed() from public, anon, authenticated;

select from _patch_fn('monitor_watch()'::regprocedure,
  'declare d record; g record; a record; n int := 0;
begin',
  'declare d record; g record; a record; n int := 0;
begin
  perform _demo_sensor_feed();');
