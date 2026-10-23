-- Follow-through report: how well each location follows through on what Service Call Proof asks of it.
-- Counted from the app's own records, each with a clear deadline:
--   code      a technician waited more than 10 min for the check-in code (labor was running)
--   approval  a request for more money waited more than 24 h for an answer
--   confirm   a contractor-entered call waited more than 24 h to be confirmed
--   bill      a contractor's bill waited more than 7 days for approval
--   flag      a flag waited more than 3 days to be looked at
--   visitor   an unexpected visitor waited more than 1 day to be taken care of
--   late_bill a late invoice wasn't chased within 2 days
--   pm        a maintenance plan a contractor proposed waited more than 7 days for an answer
-- The owner turns it on; when more than X% (standard 5%) of items in the last 30 days were missed AND at least N (standard 3),
-- the owner gets a weekly alert. An emergency call where the technician waits 15+ min for the code alerts the owner right away.

alter table customers add column if not exists followthrough_on boolean not null default false;
alter table customers add column if not exists followthrough_pct numeric(4,1) not null default 5 check (followthrough_pct between 1 and 50);
alter table customers add column if not exists followthrough_min int not null default 3 check (followthrough_min between 1 and 50);
alter table customers add column if not exists followthrough_to uuid[];

-- The labels people see
create or replace function _ft_label(k text) returns text language sql immutable as $$
  select case k when 'code' then 'Check-in code waits' when 'approval' then 'Requests for more money'
    when 'confirm' then 'Contractor-entered calls to confirm' when 'bill' then 'Bills to approve'
    when 'flag' then 'Flags to review' when 'visitor' then 'Unexpected visitors'
    when 'late_bill' then 'Late invoices to chase' when 'pm' then 'Maintenance plans to answer' else k end
$$;

create or replace function _ft_dur(i interval) returns text language sql immutable as $$
  select case when i < interval '1 hour' then greatest(1, floor(extract(epoch from i) / 60))::int || ' min'
              when i < interval '48 hours' then round(extract(epoch from i) / 3600)::int || ' h'
              else round(extract(epoch from i) / 86400)::int || ' days' end
$$;

-- Every item with a deadline in the window: done on time, or missed. Items still inside their deadline aren't counted yet.
create or replace function _ft_items(p_customer uuid, p_from timestamptz, p_to timestamptz)
returns table (kind text, site_id uuid, work_order_id uuid, number int, at timestamptz, missed boolean, detail text, wait_min int, dollars numeric)
language sql stable security definer set search_path = public as $$
  -- a visit that finished without the code is a miss, but its whole visit isn't counted as waiting
  select 'code', w.site_id, w.id, w.number::int, v.arrived_at, x.never or x.wt > 10,
         case when x.never then 'Technician never got the check-in code' else format('Technician waited %s for the check-in code', _ft_dur(make_interval(mins => x.wt))) end,
         case when x.never then 0 else x.wt end,
         case when not x.never and x.wt > 10 then round(x.wt / 60.0 * coalesce(_labor_rate_eff(w.id), 0), 2) else 0 end
    from visits v join work_orders w on w.id = v.work_order_id
    cross join lateral (select v.checkin_at is null and coalesce(v.departed_at, v.completed_at) is not null never,
                               greatest(0, floor(extract(epoch from (coalesce(v.checkin_at, now()) - v.arrived_at)) / 60))::int wt) x
   where w.customer_id = p_customer and v.checkin_required and v.status::text <> 'cancelled' and v.arrived_at >= p_from and v.arrived_at < p_to
     and (v.checkin_at is not null or x.never or now() - v.arrived_at > interval '10 minutes')
  union all
  select 'approval', w.site_id, w.id, w.number::int, l.requested_at, coalesce(l.decided_at, now()) - l.requested_at > interval '24 hours',
         format('Request for $%s more (%s) %s', trim_scale(l.amount), l.description,
                case when l.decided_at is null then 'still unanswered after ' || _ft_dur(now() - l.requested_at)
                     else 'answered after ' || _ft_dur(l.decided_at - l.requested_at) end), null, 0
    from po_lines l join work_orders w on w.id = l.work_order_id
   where w.customer_id = p_customer and l.seq > 0 and l.requested_at >= p_from and l.requested_at < p_to
     and (l.decided_at is not null or now() - l.requested_at > interval '24 hours')
  union all
  select 'confirm', w.site_id, w.id, w.number::int, w.created_at, coalesce(w.store_confirmed_at, now()) - w.created_at > interval '24 hours',
         case when w.store_confirmed_at is null then 'Not confirmed after ' || _ft_dur(now() - w.created_at)
              else 'Confirmed after ' || _ft_dur(w.store_confirmed_at - w.created_at) end, null, 0
    from work_orders w
   where w.customer_id = p_customer and w.source = 'contractor' and w.status <> 'cancelled' and w.created_at >= p_from and w.created_at < p_to
     and (w.store_confirmed_at is not null or now() - w.created_at > interval '24 hours')
  union all
  select 'bill', w.site_id, w.id, w.number::int, i.entered_at, coalesce(i.reviewed_at, now()) - i.entered_at > interval '7 days',
         format('Bill for $%s %s', trim_scale(i.total),
                case when i.reviewed_at is null then 'waiting ' || _ft_dur(now() - i.entered_at) else 'approved after ' || _ft_dur(i.reviewed_at - i.entered_at) end),
         null, case when coalesce(i.reviewed_at, now()) - i.entered_at > interval '7 days' then i.total else 0 end
    from call_invoices i join work_orders w on w.id = i.work_order_id
   where w.customer_id = p_customer and i.entered_at >= p_from and i.entered_at < p_to
     and (i.reviewed_at is not null or now() - i.entered_at > interval '7 days')
  union all
  select 'flag', w.site_id, w.id, w.number::int, g.triggered_at, coalesce(x.seen, now()) - g.triggered_at > interval '3 days',
         case when x.seen is null then 'Flag not looked at after ' || _ft_dur(now() - g.triggered_at) else 'Flag looked at after ' || _ft_dur(x.seen - g.triggered_at) end
           || ': ' || left(coalesce(g.description, g.flag::text), 120), null, 0
    from guardrail_flags g join work_orders w on w.id = g.work_order_id
    cross join lateral (select least(g.store_ack_at, g.resolved_at) seen) x
   where w.customer_id = p_customer and g.visible_to_customer and g.flag::text not in ('billing_late', 'checkin_unverified', 'call_unconfirmed')
     and g.triggered_at >= p_from and g.triggered_at < p_to
     and (x.seen is not null or now() - g.triggered_at > interval '3 days')
  union all
  select 'visitor', sv.site_id, null, null, sv.recorded_at, coalesce(sv.resolved_at, now()) - sv.recorded_at > interval '1 day',
         format('Unexpected visitor %s%s %s', coalesce(sv.visitor_name, ''), coalesce(' (' || sv.company || ')', ''),
                case when sv.resolved_at is null then 'not taken care of after ' || _ft_dur(now() - sv.recorded_at)
                     else 'taken care of after ' || _ft_dur(sv.resolved_at - sv.recorded_at) end), null, 0
    from site_visitors sv join sites s on s.id = sv.site_id
   where s.customer_id = p_customer and sv.recorded_at >= p_from and sv.recorded_at < p_to
     and (sv.resolved_at is not null or now() - sv.recorded_at > interval '1 day')
  union all
  select 'late_bill', w.site_id, w.id, w.number::int, w.invoice_due_at,
         w.bill_requested_at is null or w.bill_requested_at > w.invoice_due_at + interval '2 days',
         case when w.bill_requested_at is null then 'Late invoice never chased' else 'Late invoice chased after ' || _ft_dur(w.bill_requested_at - w.invoice_due_at) end,
         null, 0
    from work_orders w
   where w.customer_id = p_customer and w.invoice_due_at >= p_from and w.invoice_due_at < p_to and w.invoice_due_at < now() - interval '2 days'
     and not exists (select 1 from call_invoices i where i.work_order_id = w.id and i.entered_at <= w.invoice_due_at + interval '2 days')
  union all
  select 'pm', p.site_id, null, null, p.updated_at, p.approval::text = 'proposed',
         case when p.approval::text = 'proposed' then format('Maintenance plan "%s" not answered after %s', p.name, _ft_dur(now() - p.updated_at))
              else format('Maintenance plan "%s" answered', p.name) end, null, 0
    from pm_plans p
   where p.customer_id = p_customer and p.proposed_side = 'contractor' and p.updated_at >= p_from and p.updated_at < p_to
     and (p.approval::text <> 'proposed' or now() - p.updated_at > interval '7 days')
$$;
revoke execute on function _ft_items(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- Who gets the alerts: the people the owner picked, or else the company's admins
create or replace function _ft_recipients(p_customer uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select array_agg(p.id) from customers c join profiles p on p.id = any(c.followthrough_to) and p.customer_id = c.id and p.active where c.id = p_customer),
    (select array_agg(p.id) from profiles p where p.customer_id = p_customer and p.is_org_admin and p.active),
    '{}')
$$;
revoke execute on function _ft_recipients(uuid) from public, anon, authenticated;

-- The report. p_viewer limits it to the locations that person sees (null = everything, for the weekly check).
create or replace function _ft_report(p_customer uuid, p_days int, p_viewer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c customers; d int := least(greatest(coalesce(p_days, 30), 7), 365); f timestamptz; r jsonb;
begin
  f := now() - make_interval(days => d);
  select * into c from customers where id = p_customer;
  with ft as materialized (
    select i.* from _ft_items(p_customer, f, now()) i where p_viewer is null or profile_sees_site(p_viewer, i.site_id)
  ), agg as (
    select count(*)::int tot, (count(*) filter (where missed))::int mis from ft
  )
  select jsonb_build_object(
    'days', d, 'from', f, 'to', now(),
    'on', c.followthrough_on, 'limit_pct', c.followthrough_pct, 'limit_min', c.followthrough_min,
    'recipients', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name) order by p.full_name), '[]') from profiles p where p.id = any(_ft_recipients(p_customer))),
    'chosen', coalesce(to_jsonb(c.followthrough_to), '[]'),
    'total', agg.tot, 'missed', agg.mis,
    'pct', case when agg.tot > 0 then round(100.0 * agg.mis / agg.tot, 1) else 0 end,
    'over', agg.mis >= c.followthrough_min and agg.tot > 0 and 100.0 * agg.mis / agg.tot > c.followthrough_pct,
    'wait_min', (select coalesce(sum(wait_min), 0) from ft where kind = 'code' and missed),
    'wait_dollars', (select coalesce(sum(dollars), 0) from ft where kind = 'code' and missed),
    'bills_waiting', (select coalesce(sum(dollars), 0) from ft where kind = 'bill' and missed),
    'by_kind', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'label', _ft_label(kind), 'total', n, 'missed', m) order by m desc, n desc), '[]')
                  from (select kind, count(*) n, count(*) filter (where missed) m from ft group by kind) k),
    'by_site', (select coalesce(jsonb_agg(jsonb_build_object('site_id', s.id, 'name', s.name, 'total', n, 'missed', m,
                   'pct', case when n > 0 then round(100.0 * m / n, 1) else 0 end,
                   'people', (select coalesce(jsonb_agg(p.full_name order by p.full_name), '[]') from profiles p
                               where p.customer_id = p_customer and p.active and not p.is_org_admin and profile_sees_site(p.id, s.id)))
                   order by m desc, s.name), '[]')
                  from (select site_id, count(*) n, count(*) filter (where missed) m from ft group by site_id) k join sites s on s.id = k.site_id),
    'misses', (select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'label', _ft_label(x.kind), 'site', s.name, 'number', x.number,
                   'work_order_id', x.work_order_id, 'at', x.at, 'detail', x.detail, 'dollars', x.dollars) order by x.at desc), '[]')
                 from (select * from ft where missed order by at desc limit 200) x left join sites s on s.id = x.site_id)
  ) into r from agg;
  return r;
end $$;
revoke execute on function _ft_report(uuid, int, uuid) from public, anon, authenticated;

-- Anyone at the company can see the report for the locations they see; the owner sees everything.
create or replace function followthrough_report(p_days int default 30) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null then raise exception 'Only a customer account has a follow-through report.'; end if;
  return _ft_report(m.customer_id, p_days, case when m.is_org_admin or store_can(m.customer_id, 'company') then null else m.id end);
end $$;
revoke execute on function followthrough_report(int) from public, anon;
grant execute on function followthrough_report(int) to authenticated;

create or replace function set_followthrough(p_on boolean, p_pct numeric, p_min int, p_to uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); bad int;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'company') then raise exception 'You don''t have permission to change company settings.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if p_pct is null or p_pct < 1 or p_pct > 50 then raise exception 'Pick a percentage from 1 to 50.'; end if;
  if p_min is null or p_min < 1 or p_min > 50 then raise exception 'Pick a number of misses from 1 to 50.'; end if;
  select count(*) into bad from unnest(coalesce(p_to, '{}')) x where not exists (select 1 from profiles p where p.id = x and p.customer_id = m.customer_id and p.active);
  if bad > 0 then raise exception 'Pick people from your own team.'; end if;
  perform _allow_internal(true);
  update customers set followthrough_on = coalesce(p_on, false), followthrough_pct = p_pct, followthrough_min = p_min,
         followthrough_to = nullif(p_to, '{}') where id = m.customer_id;
  perform _end_internal();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function set_followthrough(boolean, numeric, int, uuid[]) from public, anon;
grant execute on function set_followthrough(boolean, numeric, int, uuid[]) to authenticated;

-- Weekly: tell the owner when follow-through slipped past their limit
create or replace function followthrough_watch() returns int
language plpgsql security definer set search_path = public as $$
declare c record; r jsonb; n int := 0; msg text;
begin
  for c in select id from customers where followthrough_on loop
    r := _ft_report(c.id, 30, null);
    if (r->>'over')::boolean then
      msg := format('Follow-through report: %s of %s items were missed in the last 30 days (%s%%), over your %s%% limit.',
                    r->>'missed', r->>'total', trim_scale((r->>'pct')::numeric), trim_scale((r->>'limit_pct')::numeric));
      if (r->>'wait_min')::int > 0 then
        msg := msg || format(' Technicians waited %s for check-in codes%s.', _ft_dur(make_interval(mins => (r->>'wait_min')::int)),
                             case when (r->>'wait_dollars')::numeric > 0 then format(', about $%s of labor', round((r->>'wait_dollars')::numeric)) else '' end);
      end if;
      if (r->>'bills_waiting')::numeric > 0 then
        msg := msg || format(' Bills totaling $%s waited more than 7 days for approval.', round((r->>'bills_waiting')::numeric));
      end if;
      msg := msg || ' Open the Follow-through report on your dashboard for the list.';
      perform _notify(x, null, 'followthrough', msg, 'ft:' || c.id || ':' || to_char(now(), 'IYYY-IW')) from unnest(_ft_recipients(c.id)) x;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function followthrough_watch() from public, anon, authenticated;

-- Emergency calls: the owner hears right away when a technician has waited 15+ minutes for the code
create or replace function checkin_watch() returns integer
language plpgsql security definer set search_path = public as $$
declare r record; mins int; n int := 0; rate numeric; cost numeric; step int; msg text; who text;
begin
  for r in select v.id, v.arrived_at, v.work_order_id, w.number, w.site_id, w.customer_id, w.priority, s.name site_name, p.full_name tech
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
      perform _notify_office(r.work_order_id, 'checkin', format('Call #%s: %s has waited %s min at %s — no one on site has given the check-in code yet.',
        r.number, r.tech, mins, r.site_name), 'door:' || r.id || ':office');
      perform _raise_flag(r.work_order_id, 'checkin_unverified', format(
        'Technician waited %s+ minutes on site for the check-in code (labor was running).', mins), false, true);
    end if;
    if mins >= 15 and r.priority = 1 and exists (select 1 from customers where id = r.customer_id and followthrough_on) then
      perform _notify(x, r.work_order_id, 'followthrough', format(
        'EMERGENCY CALL #%s at %s: the technician has waited %s min and no one has given the check-in code%s.',
        r.number, r.site_name, mins, case when rate > 0 then format(' (about $%s of labor so far)', cost) else '' end), 'ftemerg:' || r.id)
      from unnest(_ft_recipients(r.customer_id)) x;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- The demo companies show the report switched on
do $$ begin
  perform set_config('app.demo_guard_off', 'on', true);
  update customers set followthrough_on = true where name like '%(demo)' and kind <> 'residential';
  perform set_config('app.demo_guard_off', 'off', true);
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-followthrough', '7 13 * * 1', 'select public.followthrough_watch()');
  end if;
end $$;
