-- ServicePro 0010 — The tech is at the door waiting for the check-in code, and labor is running.
-- Alert the store at once, again at 5 minutes (whole team + contractor office), and flag it at 10 minutes.

create or replace function checkin_watch() returns int
language plpgsql security definer set search_path = public as $$
declare r record; mins int; n int := 0; rate numeric; cost numeric;
begin
  for r in select v.id, v.arrived_at, v.work_order_id, w.number, w.site_id, w.customer_id, s.name site_name, p.full_name tech
             from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id
             join profiles p on p.id = v.technician_id
            where v.status = 'on_site' and v.checkin_required and v.checkin_at is null and v.arrived_at is not null loop
    mins := floor(extract(epoch from (now() - r.arrived_at)) / 60);
    rate := _labor_rate_eff(r.work_order_id);
    cost := round(mins / 60.0 * rate, 2);
    -- Right away: everyone at the store who can see this location
    perform _notify(p.id, r.work_order_id, 'checkin', format(
      'Technician %s is at %s for call #%s and needs your check-in code. Labor time is running.', r.tech, r.site_name, r.number),
      'door:' || r.id || ':0')
    from profiles p where p.customer_id = r.customer_id and p.active and profile_sees_site(p.id, r.site_id);
    if mins >= 5 then
      perform _notify(p.id, r.work_order_id, 'checkin', format(
        'STILL WAITING: technician has waited %s min at %s (call #%s) for the check-in code%s. Please give the code now.',
        mins, r.site_name, r.number, case when rate > 0 then format(' — about $%s of labor so far', cost) else '' end),
        'door:' || r.id || ':5')
      from profiles p where p.customer_id = r.customer_id and p.active and profile_sees_site(p.id, r.site_id);
      perform _notify_office(r.work_order_id, 'checkin', format('Call #%s: %s has waited %s min at %s for the store''s check-in code.',
        r.number, r.tech, mins, r.site_name), 'door:' || r.id || ':5');
    end if;
    if mins >= 10 then
      perform _raise_flag(r.work_order_id, 'checkin_unverified', format(
        'Technician waited %s+ minutes on site for the store''s check-in code (labor was running).', mins), false, true);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-door', '* * * * *', 'select public.checkin_watch()');
  end if;
end $$;
