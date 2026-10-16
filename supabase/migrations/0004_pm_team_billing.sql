-- =====================================================================
-- ServicePro v2 — preventive maintenance, agreements, teams & approval
-- chains, timecards, platform fees, wholesaler commission.
-- =====================================================================

-- ---------- Preventive maintenance -----------------------------------
-- Daily: create PM work orders ahead of the due date. Nobody has to remember.
create or replace function pm_generate(p_today date default current_date) returns int
language plpgsql security definer set search_path = public as $$
declare p pm_plans; w work_orders; n int := 0; s sites; cov record; flat numeric;
begin
  for p in select * from pm_plans pl where pl.active and pl.next_due_on - pl.lead_days <= p_today
             and not exists (select 1 from work_orders x where x.pm_plan_id = pl.id
                             and x.status not in ('completed','invoiced','cancelled')) loop
    select * into s from sites where id = p.site_id;
    insert into work_orders (kind, contractor_id, customer_id, site_id, equipment_id, trade_id, agreement_id, pm_plan_id,
                             priority, issue_description, checklist, due_on, require_checkin, require_checkout)
    values ('pm', p.contractor_id, p.customer_id, p.site_id, p.equipment_id, p.trade_id,
            coalesce(p.agreement_id, (active_agreement(p.contractor_id, p.site_id)).id), p.id, 3,
            p.name || ' — due ' || to_char(p.next_due_on, 'Mon DD, YYYY'), p.checklist, p.next_due_on,
            s.require_checkin, s.require_checkout)
    returning * into w;
    select * into cov from _coverage(w.id);
    flat := case when cov.pm then 0 else coalesce(p.price, 0) end;
    perform _allow_internal();
    update work_orders set flat_amount = flat where id = w.id;
    perform _end_internal();
    -- The PM visit's authorized amount: flat price, $0 under agreement, or open (T&M) if no price
    if p.price is not null or cov.pm then
      insert into po_lines (work_order_id, seq, kind, amount, description, status, decided_at)
      values (w.id, 0, 'pm', flat, case when cov.pm then 'PM visit — covered by agreement' else 'PM visit (flat price)' end,
              'approved', now());
    end if;
    perform _notify_customer(w.id, 'pm_due', format('PM scheduled: %s at %s, due %s.', p.name, s.name, to_char(p.next_due_on, 'Mon DD')));
    perform _notify_office(w.id, 'pm_due', format('PM #%s created: %s at %s, due %s — assign a technician.',
      w.number, p.name, s.name, to_char(p.next_due_on, 'Mon DD')));
    n := n + 1;
  end loop;
  -- Overdue PMs: tell both sides once a week until done
  for w in select * from work_orders where kind = 'pm' and status not in ('completed','invoiced','cancelled') and due_on < p_today loop
    perform _notify_customer(w.id, 'pm_overdue', format('PM OVERDUE %s days: call #%s — %s.', p_today - w.due_on, w.number, w.issue_description),
      'pm_overdue:' || w.id || ':' || to_char(p_today, 'IYYY-IW'));
    perform _notify_office(w.id, 'pm_overdue', format('PM OVERDUE %s days: #%s — %s.', p_today - w.due_on, w.number, w.issue_description),
      'pm_overdue:' || w.id || ':' || to_char(p_today, 'IYYY-IW'));
  end loop;
  return n;
end $$;

-- What the store dashboard shows until each PM is done (cannot be dismissed)
create or replace view pm_status with (security_invoker = true) as
select w.id as work_order_id, w.number, w.customer_id, w.site_id, w.contractor_id, w.pm_plan_id, w.due_on, w.status,
       w.issue_description,
       case when w.due_on < current_date then 'overdue'
            when w.due_on <= current_date + 7 then 'due'
            else 'upcoming' end as pm_state,
       greatest(0, current_date - w.due_on) as days_overdue
from work_orders w
where w.kind = 'pm' and w.status not in ('completed','invoiced','cancelled');

-- PM completion rate per customer (on-time = completed on or before due date)
create or replace view pm_compliance with (security_invoker = true) as
select w.contractor_id, w.customer_id,
       count(*) filter (where w.status in ('completed','invoiced')) as done,
       count(*) filter (where w.status in ('completed','invoiced') and w.completed_at::date <= w.due_on) as on_time,
       count(*) filter (where w.status not in ('completed','invoiced','cancelled') and w.due_on < current_date) as overdue
from work_orders w where w.kind = 'pm' and w.status <> 'cancelled'
group by w.contractor_id, w.customer_id;

-- ---------- Maintenance agreements -----------------------------------
create or replace function offer_agreement(p_customer uuid, p_name text, p_starts date, p_ends date,
  p_coverage coverage_kind, p_fee numeric, p_interval fee_interval, p_all_sites boolean default true,
  p_site_ids uuid[] default null, p_response_emergency_min int default null, p_response_normal_min int default null,
  p_diagnosis_amount numeric default null, p_labor_discount_pct numeric default 0, p_parts_discount_pct numeric default 0)
returns agreements language plpgsql security definer set search_path = public as $$
declare m profiles := me(); a agreements;
begin
  if not (m.contractor_id is not null and (m.is_org_admin or m.can_bill)) then raise exception 'Only the contractor office can offer agreements.'; end if;
  if not exists (select 1 from customer_contractors where contractor_id = m.contractor_id and customer_id = p_customer) then
    raise exception 'You do not serve that customer.';
  end if;
  insert into agreements (contractor_id, customer_id, name, starts_on, ends_on, all_sites, coverage, fee_amount, fee_interval,
                          next_fee_on, response_emergency_min, response_normal_min, diagnosis_amount,
                          labor_discount_pct, parts_discount_pct, status)
  values (m.contractor_id, p_customer, p_name, p_starts, p_ends, p_all_sites, p_coverage, p_fee, p_interval,
          p_starts, p_response_emergency_min, p_response_normal_min, p_diagnosis_amount,
          p_labor_discount_pct, p_parts_discount_pct, 'offered')
  returning * into a;
  if not p_all_sites then
    insert into agreement_sites select a.id, unnest(p_site_ids);
  end if;
  perform _notify(p.id, null, 'approval_request', format('%s offered a maintenance agreement: %s.',
    (select name from contractors where id = m.contractor_id), p_name))
  from profiles p where p.customer_id = p_customer and p.active and p.is_org_admin;
  return a;
end $$;

create or replace function accept_agreement(p_agreement uuid) returns agreements
language plpgsql security definer set search_path = public as $$
declare a agreements;
begin
  select * into a from agreements where id = p_agreement for update;
  if not is_customer_admin(a.customer_id) then raise exception 'Only the customer''s administrator can accept agreements.'; end if;
  if a.status <> 'offered' then raise exception 'This agreement is %.', a.status; end if;
  update agreements set status = 'active', accepted_by = auth.uid(), accepted_at = now() where id = a.id returning * into a;
  return a;
end $$;

-- Agreement fees that should be invoiced now (office runs this, or the QuickBooks sync does)
create or replace view agreement_fees_due with (security_invoker = true) as
select a.id as agreement_id, a.contractor_id, a.customer_id, a.name, a.fee_amount, a.fee_interval, a.next_fee_on
from agreements a where a.status = 'active' and a.fee_amount > 0 and a.next_fee_on <= current_date and a.next_fee_on <= a.ends_on;

create or replace function mark_agreement_fee_invoiced(p_agreement uuid) returns agreements
language plpgsql security definer set search_path = public as $$
declare a agreements;
begin
  select * into a from agreements where id = p_agreement for update;
  if not is_contractor_office(a.contractor_id) then raise exception 'Not allowed.'; end if;
  update agreements set next_fee_on = (next_fee_on + case fee_interval when 'monthly' then interval '1 month'
                                       when 'quarterly' then interval '3 months' else interval '1 year' end)::date
   where id = a.id returning * into a;
  return a;
end $$;

-- What the agreement saved the store: covered work valued at normal rates
create or replace function agreement_value(p_agreement uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a agreements; c contractors; labor_val numeric; parts_val numeric; paid numeric; months numeric;
begin
  select * into a from agreements where id = p_agreement;
  if not (is_customer_member(a.customer_id) or is_contractor_office(a.contractor_id)) then raise exception 'Not allowed.'; end if;
  select * into c from contractors where id = a.contractor_id;
  select coalesce(sum(round(v.labor_minutes_billed / 60.0 * c.labor_rate, 2) - v.labor_amount), 0) into labor_val
    from visits v join work_orders w on w.id = v.work_order_id where w.agreement_id = a.id and v.status = 'done';
  select coalesce(sum(pu.quantity * part_price(pu.part_id) - pu.total_price), 0) into parts_val
    from parts_used pu join work_orders w on w.id = pu.work_order_id where w.agreement_id = a.id;
  months := greatest(1, extract(year from age(least(current_date, a.ends_on), a.starts_on)) * 12
                        + extract(month from age(least(current_date, a.ends_on), a.starts_on)));
  paid := a.fee_amount * case a.fee_interval when 'monthly' then months when 'quarterly' then ceil(months / 3) else ceil(months / 12) end;
  return jsonb_build_object('agreement', a.name, 'fees_paid', paid, 'covered_labor', labor_val, 'covered_parts', parts_val,
    'value_received', labor_val + parts_val,
    'response', (select jsonb_build_object('calls', count(*), 'met', count(*) filter (where response_met),
                   'missed', count(*) filter (where response_met = false))
                 from work_orders where agreement_id = a.id and response_due_at is not null));
end $$;

-- ---------- Teams: the org admin manages its own people --------------
-- Fields an admin may set on a member. Nobody can raise their own permissions.
create or replace function update_member(p_profile uuid, p_title text default null, p_perms jsonb default '{}',
  p_site_ids uuid[] default null, p_active boolean default null)
returns profiles language plpgsql security definer set search_path = public as $$
declare m profiles := me(); t profiles;
begin
  select * into t from profiles where id = p_profile for update;
  if t.id is null then raise exception 'Unknown person.'; end if;
  if not m.is_org_admin or (t.customer_id is distinct from m.customer_id and t.contractor_id is distinct from m.contractor_id)
     or (m.customer_id is null and m.contractor_id is null) then
    raise exception 'Only your organization''s administrator can change people.';
  end if;
  if t.id = m.id and p_perms ? 'is_org_admin' and not (p_perms->>'is_org_admin')::boolean then
    raise exception 'You cannot remove your own administrator rights.';
  end if;
  update profiles set
    title          = coalesce(p_title, title),
    active         = coalesce(p_active, active),
    is_org_admin   = coalesce((p_perms->>'is_org_admin')::boolean, is_org_admin),
    is_technician  = case when contractor_id is not null then coalesce((p_perms->>'is_technician')::boolean, is_technician) else false end,
    can_dispatch   = case when contractor_id is not null then coalesce((p_perms->>'can_dispatch')::boolean, can_dispatch) else false end,
    can_bill       = case when contractor_id is not null then coalesce((p_perms->>'can_bill')::boolean, can_bill) else false end,
    hourly_cost    = case when contractor_id is not null and p_perms ? 'hourly_cost' then (p_perms->>'hourly_cost')::numeric else hourly_cost end,
    can_open_calls = case when customer_id is not null then coalesce((p_perms->>'can_open_calls')::boolean, can_open_calls) else false end,
    can_approve    = case when customer_id is not null then coalesce((p_perms->>'can_approve')::boolean, can_approve) else false end,
    approval_limit = case when customer_id is not null and p_perms ? 'approval_limit' then (p_perms->>'approval_limit')::numeric else approval_limit end,
    can_manage_pm  = case when customer_id is not null then coalesce((p_perms->>'can_manage_pm')::boolean, can_manage_pm) else false end,
    can_see_billing= case when customer_id is not null then coalesce((p_perms->>'can_see_billing')::boolean, can_see_billing) else false end,
    all_sites      = coalesce((p_perms->>'all_sites')::boolean, all_sites)
  where id = t.id returning * into t;
  if p_site_ids is not null then
    delete from profile_sites where profile_id = t.id;
    insert into profile_sites (profile_id, site_id)
    select t.id, s.id from sites s where s.id = any(p_site_ids) and s.customer_id = t.customer_id;
  end if;
  return t;
end $$;

-- Each person chooses what they are told about
create or replace function set_my_notifications(p_notify jsonb) returns profiles
language sql security definer set search_path = public as $$
  update profiles set notify = notify || p_notify where id = auth.uid() returning *
$$;

-- The store sets / changes its standing backup check-in code
create or replace function set_backup_code(p_site uuid, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if not (is_customer_admin(s.customer_id) or exists (select 1 from profiles where id = auth.uid() and customer_id = s.customer_id
          and can_manage_pm and profile_sees_site(id, p_site))) then
    raise exception 'Only the store''s administrator can set the backup code.';
  end if;
  if p_code !~ '^[0-9]{4,8}$' then raise exception 'Use 4 to 8 digits.'; end if;
  update sites set backup_code_hash = extensions.crypt(p_code, extensions.gen_salt('bf')) where id = p_site;
end $$;

-- Replace a customer's approval chain in one call.
-- p_steps: [{"profile_id":…, "backup_profile_id":…}, …] in order, lowest limit first.
create or replace function save_approval_chain(p_chain uuid, p_name text, p_all_sites boolean, p_site_ids uuid[],
  p_timeout_minutes int, p_emergency_profile uuid, p_steps jsonb)
returns approval_chains language plpgsql security definer set search_path = public as $$
declare m profiles := me(); c approval_chains; st jsonb; i int := 0;
begin
  if not m.is_org_admin or m.customer_id is null then raise exception 'Only the customer''s administrator can edit approval chains.'; end if;
  if jsonb_array_length(coalesce(p_steps, '[]')) = 0 then raise exception 'Add at least one approver.'; end if;
  if p_chain is null then
    insert into approval_chains (customer_id, name, all_sites, timeout_minutes, emergency_profile_id)
    values (m.customer_id, p_name, p_all_sites, p_timeout_minutes, p_emergency_profile) returning * into c;
  else
    update approval_chains set name = p_name, all_sites = p_all_sites, timeout_minutes = p_timeout_minutes,
           emergency_profile_id = p_emergency_profile
     where id = p_chain and customer_id = m.customer_id returning * into c;
    if c.id is null then raise exception 'Unknown chain.'; end if;
    delete from approval_chain_steps where chain_id = c.id;
    delete from approval_chain_sites where chain_id = c.id;
  end if;
  for st in select * from jsonb_array_elements(p_steps) loop
    i := i + 1;
    if not exists (select 1 from profiles where id = (st->>'profile_id')::uuid and customer_id = m.customer_id and can_approve) then
      raise exception 'Step %: that person cannot approve spending.', i;
    end if;
    insert into approval_chain_steps (chain_id, step_no, profile_id, backup_profile_id)
    values (c.id, i, (st->>'profile_id')::uuid, (st->>'backup_profile_id')::uuid);
  end loop;
  if not p_all_sites then
    insert into approval_chain_sites select c.id, s.id from sites s where s.id = any(p_site_ids) and s.customer_id = m.customer_id;
  end if;
  return c;
end $$;

-- ---------- Timecards ------------------------------------------------
-- Clock in/out and breaks from the phone (works offline; p_id comes from the phone).
create or replace function clock(p_action text, p_at timestamptz default null, p_id uuid default null, p_note text default null)
returns time_entries language plpgsql security definer set search_path = public as $$
declare m profiles := me(); t timestamptz := _device_time(p_at); e time_entries; k time_kind;
begin
  if m.contractor_id is null then raise exception 'Timecards are for contractor staff.'; end if;
  if p_action in ('in','break_start') then
    k := case when p_action = 'in' then 'shift'::time_kind else 'break' end;
    if p_id is not null and exists (select 1 from time_entries where id = p_id) then
      select * into e from time_entries where id = p_id; return e;               -- duplicate sync
    end if;
    if exists (select 1 from time_entries where profile_id = m.id and kind = k and end_at is null) then
      raise exception 'Already %.', case when k = 'shift' then 'clocked in' else 'on break' end;
    end if;
    insert into time_entries (id, profile_id, kind, start_at, note) values (coalesce(p_id, gen_random_uuid()), m.id, k, t, p_note)
    returning * into e;
  elsif p_action in ('out','break_end') then
    k := case when p_action = 'out' then 'shift'::time_kind else 'break' end;
    select * into e from time_entries where profile_id = m.id and kind = k and end_at is null order by start_at desc limit 1 for update;
    if e.id is null then raise exception 'Not %.', case when k = 'shift' then 'clocked in' else 'on break' end; end if;
    if k = 'shift' then   -- clocking out ends any open break
      update time_entries set end_at = greatest(t, start_at + interval '1 minute') where profile_id = m.id and kind = 'break' and end_at is null;
    end if;
    update time_entries set end_at = greatest(t, start_at + interval '1 minute'), note = coalesce(p_note, note) where id = e.id returning * into e;
  else
    raise exception 'Unknown action %.', p_action;
  end if;
  return e;
end $$;

-- A week of time for one person: each day's shift, breaks, job time (from visits) and drive time.
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
                where e.profile_id = p_profile and e.kind = 'break' and (e.start_at at time zone tz)::date = d::date), 0),
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

create or replace function approve_timesheet(p_profile uuid, p_week_start date) returns timesheet_approvals
language plpgsql security definer set search_path = public as $$
declare pr profiles; a timesheet_approvals;
begin
  select * into pr from profiles where id = p_profile;
  if not is_contractor_office(pr.contractor_id) or p_profile = auth.uid() then
    raise exception 'The office approves timesheets (not your own).';
  end if;
  if extract(isodow from p_week_start) <> 1 then raise exception 'Weeks start on Monday.'; end if;
  if exists (select 1 from time_entries where profile_id = p_profile and end_at is null
             and start_at < p_week_start + 7 and start_at >= p_week_start) then
    raise exception 'There is an open clock-in that week. Fix it first.';
  end if;
  insert into timesheet_approvals (profile_id, week_start, approved_by) values (p_profile, p_week_start, auth.uid())
  on conflict (profile_id, week_start) do update set approved_by = excluded.approved_by, approved_at = now()
  returning * into a;
  return a;
end $$;

-- Office correction of a time entry (logged in the audit trail; reason required)
create or replace function correct_time_entry(p_entry uuid, p_start timestamptz, p_end timestamptz, p_reason text)
returns time_entries language plpgsql security definer set search_path = public as $$
declare e time_entries; pr profiles;
begin
  select * into e from time_entries where id = p_entry for update;
  select * into pr from profiles where id = e.profile_id;
  if not is_contractor_office(pr.contractor_id) then raise exception 'Not allowed.'; end if;
  if coalesce(length(trim(p_reason)), 0) < 10 then raise exception 'Give a reason (at least 10 characters).'; end if;
  if exists (select 1 from timesheet_approvals where profile_id = e.profile_id and exported_at is not null
             and e.start_at::date between week_start and week_start + 6) then
    raise exception 'That week has already gone to payroll.';
  end if;
  update time_entries set start_at = p_start, end_at = p_end,
         note = coalesce(note || ' | ', '') || 'Corrected: ' || trim(p_reason) where id = e.id returning * into e;
  delete from timesheet_approvals where profile_id = e.profile_id and e.start_at::date between week_start and week_start + 6;
  return e;
end $$;

-- ---------- Platform billing: monthly statements & commissions -------
-- Run once a month for the previous month (service role / platform admin).
create or replace function monthly_billing_run(p_month date) returns int
language plpgsql security definer set search_path = public as $$
declare ps platform_settings; mon date := date_trunc('month', p_month)::date; r record; usage numeric; cap numeric;
  techs int; sub numeric; st monthly_statements; n int := 0; cu customers;
begin
  if not (is_platform_admin() or current_user in ('service_role','postgres')) then raise exception 'Platform admin only.'; end if;
  select * into ps from platform_settings;

  -- Contractors: usage capped at $40 × active techs; Pro adds $25 × active techs
  for r in select distinct org_id from platform_fees where org_kind = 'contractor' and billing_month = mon loop
    select coalesce(sum(amount) filter (where not waived), 0), count(distinct technician_id) into usage, techs
      from platform_fees where org_kind = 'contractor' and org_id = r.org_id and billing_month = mon;
    cap := techs * ps.contractor_cap_per_tech;
    sub := case (select plan from contractors where id = r.org_id) when 'pro' then techs * ps.pro_per_tech else 0 end;
    insert into monthly_statements (org_kind, org_id, billing_month, usage_fees, cap_applied, subscription_fees, total, detail)
    values ('contractor', r.org_id, mon, least(usage, cap), case when usage > cap then cap end, sub, least(usage, cap) + sub,
            jsonb_build_object('active_techs', techs, 'uncapped_usage', usage))
    on conflict (org_kind, org_id, billing_month) do update
      set usage_fees = excluded.usage_fees, cap_applied = excluded.cap_applied, subscription_fees = excluded.subscription_fees,
          total = excluded.total, detail = excluded.detail
      where monthly_statements.status = 'draft';
    n := n + 1;
  end loop;

  -- Stores: no cap; Store Multi adds $29 per location
  for r in select c.id from customers c where c.kind = 'commercial' and (
             c.plan = 'store_multi' or exists (select 1 from platform_fees f where f.org_kind = 'customer' and f.org_id = c.id and f.billing_month = mon)) loop
    select * into cu from customers where id = r.id;
    select coalesce(sum(amount) filter (where not waived), 0) into usage
      from platform_fees where org_kind = 'customer' and org_id = r.id and billing_month = mon;
    sub := case when cu.plan = 'store_multi' and not coalesce(cu.fees_waived_until >= mon, false)
                then (select count(*) from sites where customer_id = r.id) * ps.store_multi_per_location else 0 end;
    insert into monthly_statements (org_kind, org_id, billing_month, usage_fees, subscription_fees, total, detail)
    values ('customer', r.id, mon, usage, sub, usage + sub,
            jsonb_build_object('pos', (select count(*) from platform_fees where org_kind = 'customer' and org_id = r.id and billing_month = mon)))
    on conflict (org_kind, org_id, billing_month) do update
      set usage_fees = excluded.usage_fees, subscription_fees = excluded.subscription_fees, total = excluded.total, detail = excluded.detail
      where monthly_statements.status = 'draft'
    returning * into st;
    n := n + 1;
  end loop;
  return n;
end $$;

-- When a statement is PAID: record it, and owe the wholesaler its commission on collected fees.
create or replace function mark_statement_paid(p_statement uuid) returns monthly_statements
language plpgsql security definer set search_path = public as $$
declare st monthly_statements; cu customers; ws wholesalers;
begin
  if not (is_platform_admin() or current_user in ('service_role','postgres')) then raise exception 'Platform admin only.'; end if;
  update monthly_statements set status = 'paid', paid_at = now() where id = p_statement returning * into st;
  if st.org_kind = 'customer' then
    select * into cu from customers where id = st.org_id;
    if cu.wholesaler_id is not null and st.total > 0 then
      select * into ws from wholesalers where id = cu.wholesaler_id;
      insert into commissions (wholesaler_id, statement_id, amount)
      values (ws.id, st.id, round(st.total * ws.commission_pct / 100, 2)) on conflict (statement_id) do nothing;
    end if;
  end if;
  return st;
end $$;

-- A store signs up through a wholesaler's invite code
create or replace function link_wholesaler(p_customer uuid, p_invite_code text) returns customers
language plpgsql security definer set search_path = public as $$
declare cu customers; ws wholesalers;
begin
  if not (is_customer_admin(p_customer) or is_platform_admin()) then raise exception 'Not allowed.'; end if;
  select * into ws from wholesalers where invite_code = upper(trim(p_invite_code));
  if ws.id is null then raise exception 'Unknown invite code.'; end if;
  update customers set wholesaler_id = ws.id where id = p_customer and wholesaler_id is null returning * into cu;
  if cu.id is null then raise exception 'This customer is already linked to a wholesaler.'; end if;
  return cu;
end $$;
