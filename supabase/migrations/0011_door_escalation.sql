-- ServicePro 0011 — Waiting at the door: escalate person by person, in the order of the store's own chain.
--   0 min  → first person (chain step 1; e.g. store manager)
--   5 min  → second person (step 2, plus their backup; e.g. maintenance manager)
--   10 min → third person (step 3; e.g. director) + the contractor office; flagged on the call
--   15 min → everyone at the store who covers that location
-- People who don't cover that location are skipped. No chain → everyone at the store from the start.

create or replace function _door_contacts(p_wo uuid, p_step int) returns setof uuid
language sql stable security definer set search_path = public as $$
  with w as (select * from work_orders where id = p_wo),
       c as (select ch.id from approval_chains ch, w where ch.id = (_chain_for(w.id)).id),
       ladder as (   -- the chain's people in order, keeping only those who cover this store
         select s.step_no, x.pid, dense_rank() over (order by s.step_no) as rung
         from approval_chain_steps s join c on c.id = s.chain_id
         cross join lateral (values (s.profile_id), (s.backup_profile_id)) x(pid)
         join profiles p on p.id = x.pid and p.active
         cross join w
         where x.pid is not null and profile_sees_site(x.pid, w.site_id))
  select pid from ladder where rung = p_step
  union
  -- no chain (or the chain has fewer people than this step): everyone who covers the store
  select p.id from profiles p, w
   where p.customer_id = w.customer_id and p.active and profile_sees_site(p.id, w.site_id)
     and (not exists (select 1 from ladder) or (p_step >= 4))
$$;

create or replace function checkin_watch() returns int
language plpgsql security definer set search_path = public as $$
declare r record; mins int; n int := 0; rate numeric; cost numeric; step int; msg text; who text;
begin
  for r in select v.id, v.arrived_at, v.work_order_id, w.number, w.site_id, w.customer_id, s.name site_name, p.full_name tech
             from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id
             join profiles p on p.id = v.technician_id
            where v.status = 'on_site' and v.checkin_required and v.checkin_at is null and v.arrived_at is not null loop
    mins := floor(extract(epoch from (now() - r.arrived_at)) / 60);
    rate := _labor_rate_eff(r.work_order_id);
    cost := round(mins / 60.0 * rate, 2);
    for step in 1 .. least(4, 1 + mins / 5) loop
      msg := case when step = 1
        then format('Technician %s is at %s for call #%s and needs your check-in code. Labor time is running.', r.tech, r.site_name, r.number)
        else format('NO ONE HAS ANSWERED: technician has waited %s min at %s (call #%s) for the check-in code%s. Please give the code now.',
                    mins, r.site_name, r.number, case when rate > 0 then format(' — about $%s of labor so far', cost) else '' end) end;
      perform _notify(c, r.work_order_id, 'checkin', msg, 'door:' || r.id || ':' || step) from _door_contacts(r.work_order_id, step) c;
    end loop;
    if mins >= 10 then
      perform _notify_office(r.work_order_id, 'checkin', format('Call #%s: %s has waited %s min at %s — the store has not given the check-in code.',
        r.number, r.tech, mins, r.site_name), 'door:' || r.id || ':office');
      perform _raise_flag(r.work_order_id, 'checkin_unverified', format(
        'Technician waited %s+ minutes on site for the store''s check-in code (labor was running).', mins), false, true);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
