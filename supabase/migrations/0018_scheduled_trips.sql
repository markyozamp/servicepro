-- =====================================================================
-- ServicePro 0018 — Every trip is announced to the store; the store always knows who is coming and who is inside.
--   * The office (or an owner who is also the tech) schedules each trip: which tech, the day and time window, or "now".
--     The store is told at once and the trip appears under "Expected" with its own check-in code; the tech gets it too.
--   * A tech taking a call himself ("I'm going") announces it to the store as a trip happening now.
--   * Missed window: due 9–11 and not checked in by 11 → the store and the office are told, and it's flagged.
--   * Morning reminder to the tech (6 am, the store's time) for each trip scheduled that day.
--   * A visitor the store wasn't expecting is logged with one tap; the contractor's office and the store are told.
--   * Store rule for time not verified in ServicePro: review it, or don't pay it. An invoice with no recorded visit is flagged.
--   * The contractor accepts the store's terms when signing in from the invite.
--   * Contractor record: on-time acceptance, check-ins with the code, missed windows, unscheduled visits, unexplained hours.
--   * New calls alert the contractor's technicians too (owner can turn it off).
-- =====================================================================

alter type flag_type add value if not exists 'missed_window';
alter type flag_type add value if not exists 'unscheduled_visit';
alter type flag_type add value if not exists 'no_recorded_visit';

alter table visits
  add column scheduled_start  timestamptz,
  add column scheduled_end    timestamptz,
  add column scheduled_by     uuid references profiles(id),
  add column reminder_sent_at timestamptz,
  add column missed_alert_at  timestamptz;
create index on visits (status, scheduled_start) where status in ('assigned','en_route');

alter table customer_contractors
  add column unverified_time   text not null default 'review' check (unverified_time in ('review','no_pay')),
  add column terms_accepted_at timestamptz;

alter table contractors add column tech_call_alerts boolean not null default true;

create table site_visitors (
  id            uuid primary key default gen_random_uuid(),
  site_id       uuid not null references sites(id) on delete cascade,
  customer_id   uuid not null references customers(id) on delete cascade,
  contractor_id uuid references contractors(id) on delete set null,
  visitor_name  text not null,
  company       text,
  note          text,
  recorded_by   uuid references profiles(id),
  recorded_at   timestamptz not null default now()
);
create index on site_visitors (site_id, recorded_at desc);
alter table site_visitors enable row level security;
revoke all on site_visitors from anon, authenticated;
grant select on site_visitors to authenticated;
create policy read_visitors on site_visitors for select using (
  (is_customer_member(customer_id) and can_see_site(site_id)) or (contractor_id is not null and is_contractor_office(contractor_id)));

-- ---------- Schedule a trip (office, or the owner) ----------------------------
-- p_start null = "now". Replaces a trip that hasn't started yet.
create or replace function schedule_trip(p_wo uuid, p_tech uuid, p_start timestamptz default null, p_end timestamptz default null,
  p_note text default null)
returns visits language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; t profiles; v visits; old visits; n int; s sites; when_txt text; co text;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or not is_contractor_dispatcher(w.contractor_id) then raise exception 'Only your office (or the owner) can schedule trips.'; end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'This call is closed.'; end if;
  if w.declined_at is not null then raise exception 'You declined this call.'; end if;
  select * into t from profiles where id = p_tech and is_technician and active and contractor_id = w.contractor_id;
  if t.id is null then raise exception 'Pick one of your active technicians.'; end if;
  if p_end is not null and (p_start is null or p_end <= p_start) then raise exception 'The window must end after it starts.'; end if;
  if p_start is not null and p_start < now() - interval '1 hour' then raise exception 'That time has already passed.'; end if;
  if exists (select 1 from visits where work_order_id = w.id and status in ('en_route','on_site')) then
    raise exception 'A technician is already on the way or on site. Schedule the next trip after they leave.';
  end if;
  select * into s from sites where id = w.site_id;
  co := (select name from contractors where id = w.contractor_id);

  select * into old from visits where work_order_id = w.id and status = 'assigned' limit 1 for update;
  if old.id is not null then
    update visits set status = 'cancelled', outcome_note = 'Rescheduled' where id = old.id;
    if old.technician_id <> t.id then
      perform _notify(old.technician_id, w.id, 'assigned', format('Job #%s was moved to someone else.', w.number));
    end if;
  end if;
  select coalesce(max(visit_no), 0) + 1 into n from visits where work_order_id = w.id;
  insert into visits (work_order_id, visit_no, technician_id, checkin_required, outcome_note, scheduled_start, scheduled_end, scheduled_by)
  values (w.id, n, t.id, w.require_checkin, nullif(trim(p_note), ''), coalesce(p_start, now()), p_end, m.id) returning * into v;
  if w.require_checkin then
    insert into visit_codes (visit_id, code) values (v.id, lpad((floor(random() * 10000))::int::text, 4, '0'));
  end if;
  if w.status in ('created','return_needed','waiting_parts') then perform _set_status(w.id, 'assigned'); end if;

  when_txt := case when p_start is null then 'coming now'
    else _local(p_start, w.site_id, 'Dy Mon DD HH12:MI AM') || coalesce('–' || _local(p_end, w.site_id, 'HH12:MI AM'), '') end;
  perform _notify_customer(w.id, 'assigned', format('%s (%s) is scheduled for call #%s (%s) at %s: %s%s.%s',
    t.full_name, co, w.number, _po(w), s.name, when_txt, case when n > 1 then ', return trip' else '' end,
    coalesce(' ' || nullif(trim(p_note), ''), '')));
  perform _notify(t.id, w.id, 'assigned', format('%s job #%s at %s: %s.%s', case when n > 1 then 'Return trip for' else 'New' end,
    w.number, s.name, when_txt, coalesce(' ' || nullif(trim(p_note), ''), '')));
  return v;
end $$;

-- "I'm going" without a scheduled trip = a trip announced now. (Same as 0016 plus the trip's start time.)
create or replace function tech_claim_call(p_wo uuid, p_at timestamptz default null,
  p_lat double precision default null, p_lon double precision default null)
returns visits language plpgsql security definer set search_path = public as $$
declare m profiles := me(); t timestamptz := least(_device_time(p_at), now()); w work_orders; v visits; n int;
begin
  if m.id is null or not m.is_technician or not m.active then raise exception 'Technicians only.'; end if;
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or w.contractor_id is distinct from m.contractor_id then raise exception 'This call is not for your company.'; end if;
  if w.mode <> 'verify' then raise exception 'Your dispatcher assigns this job.'; end if;
  select * into v from visits where work_order_id = w.id and status in ('assigned','en_route','on_site') limit 1 for update;
  if v.id is not null then
    if v.technician_id = m.id then
      if v.status = 'assigned' then return tech_start(v.id, p_at, p_lat, p_lon); end if;
      return v;
    end if;
    raise exception 'Already taken — % is %.', (select full_name from profiles where id = v.technician_id),
      case when v.status = 'assigned' then 'scheduled for it' else 'going' end;
  end if;
  if w.status not in ('created','assigned','return_needed','waiting_parts') then
    raise exception 'This call is % — nothing to go to.', replace(w.status::text, '_', ' ');
  end if;
  if w.declined_at is not null then raise exception 'Your office declined this call.'; end if;

  select coalesce(max(visit_no), 0) + 1 into n from visits where work_order_id = w.id;
  insert into visits (work_order_id, visit_no, technician_id, checkin_required, status, assigned_at, received_at, started_at, scheduled_start)
  values (w.id, n, m.id, w.require_checkin, 'en_route', t, t, t, t) returning * into v;
  if w.require_checkin then
    insert into visit_codes (visit_id, code) values (v.id, lpad((floor(random() * 10000))::int::text, 4, '0'));
  end if;
  perform _set_status(w.id, 'en_route');
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, event, recorded_at)
    values (m.id, w.id, v.id, p_lat, p_lon, 'en_route', t);
  end if;
  perform _notify_customer(w.id, 'eta_update', format('%s (%s) is on the way now for call #%s (%s)%s.', m.full_name,
    (select name from contractors where id = w.contractor_id), w.number, _po(w), case when n > 1 then ', return trip' else '' end));
  perform _notify_office(w.id, 'assigned', format('%s took call #%s and is on the way.', m.full_name, w.number), 'claim:' || v.id);
  return v;
end $$;

-- ---------- Every few minutes: missed windows and the morning reminder ----------
create or replace function trip_watch() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select v.id, v.work_order_id, v.technician_id, v.scheduled_start, v.scheduled_end, w.number, w.site_id, s.name site_name,
                  s.timezone tz, p.full_name tech, c.name co
             from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id
             join profiles p on p.id = v.technician_id join contractors c on c.id = w.contractor_id
            where v.status in ('assigned','en_route') and v.scheduled_by is not null and v.missed_alert_at is null
              and coalesce(v.scheduled_end, v.scheduled_start + interval '2 hours') < now() loop
    update visits set missed_alert_at = now() where id = r.id;
    perform _raise_flag(r.work_order_id, 'missed_window', format('%s (%s) was due %s–%s and had not checked in.', r.tech, r.co,
      _local(r.scheduled_start, r.site_id, 'Dy HH12:MI AM'), _local(coalesce(r.scheduled_end, r.scheduled_start + interval '2 hours'), r.site_id, 'HH12:MI AM')), false, true);
    perform _notify_customer(r.work_order_id, 'sla_missed', format('%s (%s) was due at %s by %s for call #%s and has not checked in.',
      r.tech, r.co, r.site_name, _local(coalesce(r.scheduled_end, r.scheduled_start + interval '2 hours'), r.site_id, 'HH12:MI AM'), r.number), 'missed:' || r.id);
    perform _notify_office(r.work_order_id, 'sla_missed', format('MISSED: %s was due at %s by %s for call #%s and has not checked in. The store has been told.',
      r.tech, r.site_name, _local(coalesce(r.scheduled_end, r.scheduled_start + interval '2 hours'), r.site_id, 'HH12:MI AM'), r.number), 'missed:' || r.id);
    n := n + 1;
  end loop;

  for r in select v.id, v.work_order_id, v.technician_id, v.scheduled_start, v.scheduled_end, w.number, w.site_id, s.name site_name, s.address
             from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id
            where v.status = 'assigned' and v.scheduled_by is not null and v.reminder_sent_at is null
              and (v.scheduled_start at time zone s.timezone)::date = (now() at time zone s.timezone)::date
              and (now() at time zone s.timezone)::time >= time '06:00' loop
    update visits set reminder_sent_at = now() where id = r.id;
    perform _notify(r.technician_id, r.work_order_id, 'assigned', format('Today: job #%s at %s (%s), %s%s. Tap Start driving when you leave.',
      r.number, r.site_name, r.address, _local(r.scheduled_start, r.site_id, 'HH12:MI AM'),
      coalesce('–' || _local(r.scheduled_end, r.site_id, 'HH12:MI AM'), '')), 'remind:' || r.id);
  end loop;
  return n;
end $$;

-- ---------- Store: someone is here we weren't expecting --------------------
create or replace function store_unexpected_visitor(p_site uuid, p_name text, p_contractor uuid default null,
  p_company text default null, p_note text default null)
returns site_visitors language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; r site_visitors; co text; msg text; pid uuid;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not (is_customer_member(s.customer_id) and can_see_site(s.id)) then raise exception 'Not your location.'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter the person''s name.'; end if;
  if p_contractor is not null and (_cc(s.customer_id, p_contractor)).contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  co := coalesce((select name from contractors where id = p_contractor), nullif(trim(p_company), ''), 'company not given');
  insert into site_visitors (site_id, customer_id, contractor_id, visitor_name, company, note, recorded_by)
  values (s.id, s.customer_id, p_contractor, trim(p_name), co, nullif(trim(p_note), ''), m.id) returning * into r;
  msg := format('Unscheduled visit at %s: %s (%s) is on site with no trip scheduled in ServicePro. Recorded by %s at %s.%s',
    s.name, trim(p_name), co, m.full_name, _local(r.recorded_at, s.id, 'HH12:MI AM'), coalesce(' ' || r.note, ''));
  for pid in select p.id from profiles p where p.customer_id = s.customer_id and p.active and p.id <> m.id and profile_sees_site(p.id, s.id) loop
    perform _notify(pid, null, 'arrival', msg, 'visitor:' || r.id);
  end loop;
  if p_contractor is not null then
    for pid in select p.id from profiles p where p.contractor_id = p_contractor and p.active and (p.is_org_admin or p.can_dispatch) loop
      perform _notify(pid, null, 'arrival', msg || ' Please schedule the trip with the store and have the technician check in.', 'visitor:' || r.id);
    end loop;
  end if;
  return r;
end $$;

-- ---------- Store rule for unverified time; flag an invoice with no recorded visit ----------
create or replace function set_unverified_rule(p_contractor uuid, p_rule text) returns customer_contractors
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors;
begin
  if m.customer_id is null or not is_customer_admin(m.customer_id) then raise exception 'Only your company''s admin can change this.'; end if;
  if p_rule not in ('review','no_pay') then raise exception 'Choose review or no_pay.'; end if;
  update customer_contractors set unverified_time = p_rule where customer_id = m.customer_id and contractor_id = p_contractor returning * into cc;
  if cc.contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  return cc;
end $$;

create or replace function _invoice_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare w work_orders; cc customer_contractors;
begin
  if new.check_result = '{}'::jsonb then return null; end if;
  select * into w from work_orders where id = new.work_order_id;
  cc := _cc(w.customer_id, w.contractor_id);
  if jsonb_array_length(coalesce(new.check_result->'visits', '[]')) = 0 then
    perform _raise_flag(w.id, 'no_recorded_visit', format('Invoice %s bills %s h, but no visit was recorded in ServicePro (no arrival or check-in).%s',
      new.invoice_number, new.hours_billed, case when cc.unverified_time = 'no_pay' then ' Store rule: time not verified in ServicePro is not paid.' else '' end), false, true);
  else
    update guardrail_flags set resolved_at = now(), resolution_note = 'Visit recorded'
     where work_order_id = w.id and flag = 'no_recorded_visit' and resolved_at is null;
  end if;
  if cc.unverified_time = 'no_pay' then
    update guardrail_flags set description = description || ' Store rule: time not verified in ServicePro is not paid.'
     where work_order_id = w.id and flag = 'invoice_unexplained' and resolved_at is null and description not like '%Store rule%';
  end if;
  return null;
end $$;
create trigger call_invoices_rules after insert or update on call_invoices for each row execute function _invoice_rules();

-- ---------- The contractor agrees to the store's terms when signing in from the invite ----------
create or replace function join_info(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('ok', true, 'kind', l.kind, 'name', l.full_name,
      'company', coalesce((select name from contractors where id = l.contractor_id), (select name from customers where id = l.customer_id)),
      'invited_by', (select name from customers where id = l.customer_id and l.kind = 'contractor_owner'),
      'terms', case when l.kind = 'contractor_owner' then (select jsonb_build_object('pays_travel', cc.pays_travel, 'unverified_time', cc.unverified_time,
                 'accept_emergency_min', cc.accept_emergency_min, 'accept_normal_min', cc.accept_normal_min)
               from customer_contractors cc where cc.contractor_id = l.contractor_id and cc.customer_id = l.customer_id) end,
      'used', l.used_at is not null, 'expired', l.expires_at < now())
    from join_links l where l.token = p_token), jsonb_build_object('ok', false))
$$;

create or replace function _join_terms() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'contractor_owner' and old.used_at is null and new.used_at is not null then
    update customer_contractors set terms_accepted_at = new.used_at
     where contractor_id = new.contractor_id and customer_id = new.customer_id and terms_accepted_at is null;
  end if;
  return null;
end $$;
create trigger join_links_terms after update on join_links for each row execute function _join_terms();

-- ---------- Contractor record (what the store sees about how a contractor works with it) ----------
create or replace function contractor_record(p_contractor uuid, p_days int default 90) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); cust uuid; since timestamptz := now() - make_interval(days => greatest(1, least(p_days, 730))); out jsonb;
begin
  if m.customer_id is not null then
    cust := m.customer_id;
    if (_cc(cust, p_contractor)).contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  elsif m.contractor_id is distinct from p_contractor then
    raise exception 'Not allowed.';
  end if;
  with w as (select * from work_orders x where x.contractor_id = p_contractor and (cust is null or x.customer_id = cust)
               and x.created_at >= since and x.kind <> 'pm'),
       v as (select vv.* from visits vv join w on w.id = vv.work_order_id where vv.status <> 'cancelled'),
       i as (select ci.* from call_invoices ci join w on w.id = ci.work_order_id)
  select jsonb_build_object('days', p_days,
    'calls', (select count(*) from w),
    'accept_due', (select count(*) from w where accept_due_at is not null),
    'accepted_on_time', (select count(*) from w where accept_due_at is not null and accepted_at <= accept_due_at),
    'declined', (select count(*) from w where declined_at is not null),
    'trips', (select count(*) from v where arrived_at is not null),
    'checked_in_code', (select count(*) from v where arrived_at is not null and checkin_verified),
    'arrival_by_store', (select count(*) from v where arrival_source = 'store'),
    'missed_windows', (select count(*) from v where missed_alert_at is not null),
    'unscheduled_visits', (select count(*) from site_visitors sv where sv.contractor_id = p_contractor and (cust is null or sv.customer_id = cust) and sv.recorded_at >= since),
    'repeat_calls', (select count(*) from guardrail_flags f join w on w.id = f.work_order_id where f.flag = 'repeat_call'),
    'invoices', (select count(*) from i),
    'invoices_unexplained', (select count(*) from i where (check_result->>'unexplained_h')::numeric > 0),
    'hours_unexplained', (select coalesce(sum((check_result->>'unexplained_h')::numeric), 0) from i),
    'hours_billed', (select coalesce(sum(hours_billed), 0) from i),
    'invoices_late', (select count(*) from w where invoice_due_at is not null and coalesce(invoiced_at, now()) > invoice_due_at and status in ('completed','invoiced')))
  into out;
  return out;
end $$;

-- ---------- New calls alert the technicians too (small shops; owner can turn off) ----------
create or replace function _tech_new_call() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid; s sites;
begin
  if new.mode <> 'verify' or new.source = 'contractor' then return null; end if;
  if not coalesce((select tech_call_alerts from contractors where id = new.contractor_id), false) then return null; end if;
  select * into s from sites where id = new.site_id;
  for pid in select p.id from profiles p where p.contractor_id = new.contractor_id and p.active and p.is_technician
               and not (p.is_org_admin or p.can_dispatch or p.can_bill) loop
    perform _notify(pid, new.id, 'new_call', format('New %scall #%s at %s: %s. Take it with "I''m going", or wait for the office to schedule you.',
      case when new.priority = 1 then 'EMERGENCY ' else '' end, new.number, s.name, new.issue_description), 'new_call_tech:' || new.id);
  end loop;
  return null;
end $$;
create trigger work_orders_tech_alert after insert on work_orders for each row execute function _tech_new_call();

create or replace function set_tech_call_alerts(p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not m.is_org_admin then raise exception 'Only the owner can change this.'; end if;
  update contractors set tech_call_alerts = p_on where id = m.contractor_id;
end $$;

-- ---------- Security & schedule ------------------------------------------------
revoke execute on function trip_watch(), _invoice_rules(), _join_terms(), _tech_new_call() from public, anon, authenticated;
grant execute on function schedule_trip(uuid,uuid,timestamptz,timestamptz,text), store_unexpected_visitor(uuid,text,uuid,text,text),
  set_unverified_rule(uuid,text), contractor_record(uuid,int), set_tech_call_alerts(boolean),
  tech_claim_call(uuid,timestamptz,double precision,double precision) to authenticated;
grant execute on function join_info(uuid) to anon, authenticated;
do $$ declare t text; begin
  foreach t in array array['site_visitors'] loop
    execute format('create trigger audit_%1$s after insert or update on %1$I for each row execute function _audit()', t);
  end loop;
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-trips', '*/5 * * * *', 'select public.trip_watch()');
  end if;
end $$;
