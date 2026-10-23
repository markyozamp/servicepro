-- Overnight shifts: a break counts on the day its shift started (a break after midnight no longer lands on the next day).
create or replace function timesheet(p_profile uuid, p_week_start date)
returns table (day date, shift_minutes int, break_minutes int, paid_minutes int, onsite_minutes int,
               drive_minutes int, jobs int, overtime_minutes int)
language plpgsql stable security definer set search_path = public as $$
declare pr profiles; running int := 0; tz text;
begin
  select * into pr from profiles where id = p_profile;
  select timezone into tz from contractors where id = pr.contractor_id;
  tz := coalesce(tz, 'America/Chicago');
  if not (p_profile = auth.uid() or is_contractor_office(pr.contractor_id)) then raise exception 'Not allowed.'; end if;
  for day, shift_minutes, break_minutes, onsite_minutes, drive_minutes, jobs in
    select d::date,
      coalesce((select sum(extract(epoch from (coalesce(e.end_at, now()) - e.start_at)) / 60)::int from time_entries e
                where e.profile_id = p_profile and e.kind = 'shift' and (e.start_at at time zone tz)::date = d::date), 0),
      coalesce((select sum(extract(epoch from (coalesce(e.end_at, now()) - e.start_at)) / 60)::int from time_entries e
                where e.profile_id = p_profile and e.kind = 'break'
                  and coalesce((select (s.start_at at time zone tz)::date from time_entries s where s.profile_id = p_profile and s.kind = 'shift'
                                 and s.start_at <= e.start_at order by s.start_at desc limit 1), (e.start_at at time zone tz)::date) = d::date), 0),
      coalesce((select sum(extract(epoch from (coalesce(v.completed_at, v.departed_at) - v.arrived_at)) / 60)::int from visits v
                where v.technician_id = p_profile and (v.arrived_at at time zone tz)::date = d::date and v.status = 'done'), 0),
      coalesce((select sum(extract(epoch from (v.arrived_at - v.started_at)) / 60)::int from visits v
                where v.technician_id = p_profile and (v.started_at at time zone tz)::date = d::date and v.arrived_at is not null), 0),
      (select count(*)::int from visits v where v.technician_id = p_profile and (v.arrived_at at time zone tz)::date = d::date)
    from generate_series(p_week_start, p_week_start + 6, interval '1 day') d
  loop
    paid_minutes := greatest(0, shift_minutes - break_minutes);
    overtime_minutes := greatest(0, running + paid_minutes - 2400) - greatest(0, running - 2400);   -- over 40 h/week
    running := running + paid_minutes;
    return next;
  end loop;
end $$;
