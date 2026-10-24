-- Base: schedule your techs, and timesheets.
-- Schedule: a week at a glance, one row per technician, with every trip on it (scheduled, on the way, on site, done)
-- and the calls that still need a trip. Scheduling uses the same trip rules as everywhere (schedule_trip).
-- Timesheets: the techs already clock in, out and take breaks on the phone. The office sees each tech's week (paid
-- hours, overtime over 40, time on site, driving, jobs), fixes a punch with a reason, approves the week, and
-- downloads the approved weeks for payroll.

create or replace function _office_base() returns profiles
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Not allowed.'; end if;
  if not _is_base(m.contractor_id) then raise exception 'Scheduling and timesheets come with Base.'; end if;
  return m;
end $$;

-- The week (or any span of days) for every active technician
create or replace function tech_schedule(p_from date, p_days int default 7) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := _office_base(); tz text; t0 timestamptz; t1 timestamptz;
begin
  tz := coalesce((select timezone from contractors where id = m.contractor_id), 'America/Chicago');
  t0 := (p_from::timestamp) at time zone tz;
  t1 := ((p_from + least(greatest(coalesce(p_days, 7), 1), 31))::timestamp) at time zone tz;
  return jsonb_build_object('timezone', tz, 'from', p_from, 'days', least(greatest(coalesce(p_days, 7), 1), 31),
    'techs', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name, 'phone', p.phone) order by p.full_name), '[]')
              from profiles p where p.contractor_id = m.contractor_id and p.active and p.is_technician),
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('visit_id', v.id, 'wo_id', w.id, 'number', w.number, 'tech_id', v.technician_id,
                 'status', v.status, 'start', coalesce(v.scheduled_start, v.started_at, v.arrived_at), 'end', v.scheduled_end,
                 'arrived', v.arrived_at, 'left', coalesce(v.completed_at, v.departed_at), 'visit_no', v.visit_no,
                 'site', s.name, 'customer', c.name, 'issue', left(w.issue_description, 80), 'priority', w.priority, 'mode', w.mode)
                 order by coalesce(v.scheduled_start, v.started_at, v.arrived_at)), '[]')
               from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id join customers c on c.id = w.customer_id
               where w.contractor_id = m.contractor_id and v.status <> 'cancelled'
                 and coalesce(v.scheduled_start, v.started_at, v.arrived_at) >= t0 and coalesce(v.scheduled_start, v.started_at, v.arrived_at) < t1),
    'unscheduled', (select coalesce(jsonb_agg(jsonb_build_object('wo_id', w.id, 'number', w.number, 'site', s.name, 'customer', c.name,
                 'issue', left(w.issue_description, 80), 'priority', w.priority, 'mode', w.mode, 'status', w.status, 'created_at', w.created_at,
                 'window_start', w.window_start, 'window_end', w.window_end, 'accepted', w.accepted_at is not null)
                 order by w.priority, w.created_at), '[]')
               from work_orders w join sites s on s.id = w.site_id join customers c on c.id = w.customer_id
               where w.contractor_id = m.contractor_id and w.status in ('created', 'return_needed', 'waiting_parts')
                 and w.declined_at is null and w.kind <> 'pm'
                 and not exists (select 1 from visits v where v.work_order_id = w.id and v.status in ('assigned', 'en_route', 'on_site'))));
end $$;

-- Timesheets: every tech's week at a glance
create or replace function team_week(p_week date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := _office_base();
begin
  if extract(isodow from p_week) <> 1 then raise exception 'Weeks start on Monday.'; end if;
  return (select coalesce(jsonb_agg(x order by x->>'name'), '[]') from (
    select jsonb_build_object('id', p.id, 'name', p.full_name,
      'paid_min', (select coalesce(sum(t.paid_minutes), 0) from timesheet(p.id, p_week) t),
      'overtime_min', (select coalesce(sum(t.overtime_minutes), 0) from timesheet(p.id, p_week) t),
      'onsite_min', (select coalesce(sum(t.onsite_minutes), 0) from timesheet(p.id, p_week) t),
      'drive_min', (select coalesce(sum(t.drive_minutes), 0) from timesheet(p.id, p_week) t),
      'jobs', (select coalesce(sum(t.jobs), 0) from timesheet(p.id, p_week) t),
      'open', exists (select 1 from time_entries e where e.profile_id = p.id and e.end_at is null and e.start_at >= p_week and e.start_at < p_week + 7),
      'approved_at', a.approved_at, 'approved_by', (select full_name from profiles where id = a.approved_by), 'exported_at', a.exported_at) x
    from profiles p left join timesheet_approvals a on a.profile_id = p.id and a.week_start = p_week
    where p.contractor_id = m.contractor_id and p.active and p.is_technician) t);
end $$;

-- One tech's week: the days and every punch
create or replace function tech_week(p_profile uuid, p_week date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := _office_base(); pr profiles; tz text;
begin
  select * into pr from profiles where id = p_profile;
  if pr.contractor_id is distinct from m.contractor_id then raise exception 'Not allowed.'; end if;
  tz := coalesce((select timezone from contractors where id = m.contractor_id), 'America/Chicago');
  return jsonb_build_object('name', pr.full_name, 'timezone', tz,
    'days', (select coalesce(jsonb_agg(to_jsonb(t) order by t.day), '[]') from timesheet(p_profile, p_week) t),
    'entries', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'start', e.start_at, 'end', e.end_at, 'note', e.note) order by e.start_at), '[]')
                from time_entries e where e.profile_id = p_profile
                  and e.start_at >= (p_week::timestamp at time zone tz) and e.start_at < ((p_week + 7)::timestamp at time zone tz)));
end $$;

-- Payroll: mark the approved weeks as downloaded (so a punch can't be changed after payroll has it)
create or replace function mark_payroll_exported(p_week date) returns int
language plpgsql security definer set search_path = public as $$
declare m profiles := _office_base(); n int;
begin
  if not (m.is_org_admin or m.can_bill) then raise exception 'Only your owner or billing can send timesheets to payroll.'; end if;
  update timesheet_approvals a set exported_at = now()
   where a.week_start = p_week and a.exported_at is null
     and exists (select 1 from profiles p where p.id = a.profile_id and p.contractor_id = m.contractor_id);
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function tech_schedule(date, int), team_week(date), tech_week(uuid, date), mark_payroll_exported(date) to authenticated;
revoke execute on function _office_base() from public, anon, authenticated;
