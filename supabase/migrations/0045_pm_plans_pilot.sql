-- 1) Preventive maintenance plans the store can see and manage, and PMs done properly:
--    each plan says how long the PM should take, that once started it's finished within N days, and (optionally)
--    by the same technician. A PM that drags on, or changes technicians midway, is flagged to the store.
--    The contractor proposes plans (the store accepts); the store can create them too. PM calls follow the
--    contractor's mode (Time Verify PMs get the light bill; the plan's price becomes the PO limit).
-- 2) Pilot contractors: "I want to pilot this" from the Upgrade screen or the demo page.

alter type flag_type add value if not exists 'pm_dragging';
alter type flag_type add value if not exists 'pm_tech_changed';

alter table pm_plans add column if not exists expected_hours     numeric(6,2),
                     add column if not exists finish_within_days int not null default 2 check (finish_within_days between 1 and 30),
                     add column if not exists same_tech          boolean not null default true,
                     add column if not exists approval           text not null default 'accepted' check (approval in ('proposed','accepted','declined')),
                     add column if not exists proposed_side      text check (proposed_side in ('store','contractor')),
                     add column if not exists decided_note       text,
                     add column if not exists created_by         uuid references profiles(id),
                     add column if not exists updated_at         timestamptz not null default now();

-- How one PM went: trips, technicians, spread, time on site, checklist, finished on time / within its window
create or replace function _pm_progress(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; p pm_plans; trips int; techs int; tech_names text; first_at timestamptz; last_at timestamptz; hrs numeric;
  items int; done int; deadline date; gap int;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null then return null; end if;
  select * into p from pm_plans where id = w.pm_plan_id;
  select count(*), count(distinct technician_id), string_agg(distinct pr.full_name, ', '), min(arrived_at), max(coalesce(completed_at, departed_at, arrived_at)),
         round(coalesce(sum(extract(epoch from (coalesce(v.completed_at, v.departed_at, now()) - v.arrived_at)) / 3600), 0)::numeric, 1)
    into trips, techs, tech_names, first_at, last_at, hrs
    from visits v join profiles pr on pr.id = v.technician_id
   where v.work_order_id = p_wo and v.status <> 'cancelled' and v.arrived_at is not null;
  select max(d) into gap from (
    select (v.arrived_at::date - lag(coalesce(v.completed_at, v.departed_at, v.arrived_at)::date) over (order by v.arrived_at)) d
      from visits v where v.work_order_id = p_wo and v.status <> 'cancelled' and v.arrived_at is not null) g;
  items := coalesce(jsonb_array_length(case when jsonb_typeof(w.checklist) = 'array' then w.checklist end), 0);
  select count(*) into done from jsonb_each(coalesce(w.checklist_results, '{}')) e where coalesce((e.value->>'done')::boolean, false);
  deadline := case when first_at is not null then (first_at::date + coalesce(p.finish_within_days, 2) - 1) end;
  return jsonb_build_object('trips', trips, 'techs', techs, 'tech_names', tech_names, 'started', first_at, 'last', last_at,
    'hours', hrs, 'expected_hours', p.expected_hours, 'items', items, 'items_done', least(done, items),
    'finish_within_days', coalesce(p.finish_within_days, 2), 'deadline', deadline, 'longest_gap_days', coalesce(gap, 0),
    'done', w.status in ('completed','invoiced'), 'completed', w.completed_at, 'due_on', w.due_on,
    'on_time', case when w.status in ('completed','invoiced') then w.completed_at::date <= w.due_on end,
    'dragging', first_at is not null and (case when w.status in ('completed','invoiced') then w.completed_at::date else current_date end) > deadline,
    'tech_changed', coalesce(p.same_tech, true) and techs > 1,
    'short', w.status in ('completed','invoiced') and p.expected_hours is not null and hrs < p.expected_hours * 0.6);
end $$;
revoke execute on function _pm_progress(uuid) from public, anon, authenticated;

create or replace function pm_progress(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_see_work_order(p_wo) then raise exception 'Not allowed.'; end if;
  return _pm_progress(p_wo);
end $$;
grant execute on function pm_progress(uuid) to authenticated;

-- The plans a person can see: a store sees its locations' plans; a contractor sees the plans it services
create or replace function pm_plans_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.id is null then raise exception 'Not allowed.'; end if;
  return (select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
    select jsonb_build_object('id', p.id, 'name', p.name, 'site_id', p.site_id, 'site', s.name, 'customer_id', p.customer_id, 'customer', c.name,
      'contractor_id', p.contractor_id, 'contractor', k.name, 'equipment_id', p.equipment_id,
      'equipment', (select concat_ws(' — ', et.name, e.location_description) from equipment e left join equipment_types et on et.id = e.equipment_type_id where e.id = p.equipment_id),
      'trade_id', p.trade_id, 'frequency_months', p.frequency_months, 'next_due_on', p.next_due_on, 'lead_days', p.lead_days,
      'price', p.price, 'expected_hours', p.expected_hours, 'finish_within_days', p.finish_within_days, 'same_tech', p.same_tech,
      'checklist', p.checklist, 'active', p.active, 'approval', p.approval, 'proposed_side', p.proposed_side, 'decided_note', p.decided_note,
      'open', (select jsonb_build_object('id', w.id, 'number', w.number, 'due_on', w.due_on, 'status', w.status, 'progress', _pm_progress(w.id))
                 from work_orders w where w.pm_plan_id = p.id and w.status not in ('completed','invoiced','cancelled') order by w.created_at desc limit 1),
      'history', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'number', h.number, 'due_on', h.due_on, 'progress', _pm_progress(h.id)) order by h.due_on desc), '[]')
                 from (select * from work_orders w where w.pm_plan_id = p.id and w.status in ('completed','invoiced') order by w.due_on desc limit 4) h),
      'sort', case p.approval when 'proposed' then '0' else '1' end || to_char(p.next_due_on, 'YYYYMMDD')) x
    from pm_plans p join sites s on s.id = p.site_id join customers c on c.id = p.customer_id join contractors k on k.id = p.contractor_id
    where (m.customer_id is not null and p.customer_id = m.customer_id and can_see_site(p.site_id))
       or (m.contractor_id is not null and p.contractor_id = m.contractor_id and is_contractor_office(p.contractor_id))) q);
end $$;
grant execute on function pm_plans_list() to authenticated;

-- Create or change a plan. Store (with equipment/maintenance rights): in force at once. Contractor office: proposed, the store accepts.
create or replace function save_pm_plan(p_id uuid, p_site uuid, p_contractor uuid, p_name text, p_frequency_months int, p_next_due date,
  p_checklist jsonb, p_price numeric, p_expected_hours numeric, p_finish_within_days int, p_same_tech boolean,
  p_equipment uuid default null, p_trade smallint default null, p_lead_days int default 14, p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; side text; old pm_plans; cl jsonb := '[]'; it jsonb; nid uuid; cust uuid; con uuid;
begin
  select * into s from sites where id = p_site;
  if s.id is null then raise exception 'Pick a location.'; end if;
  cust := s.customer_id;
  if p_id is not null then
    select * into old from pm_plans where id = p_id for update;
    if old.id is null then raise exception 'Not found.'; end if;
  end if;
  if m.customer_id = cust and store_can(cust, 'equipment') and can_see_site(p_site) then side := 'store'; con := p_contractor;
  elsif m.contractor_id is not null and is_contractor_office(m.contractor_id) and exists (
          select 1 from customer_contractors cc where cc.customer_id = cust and cc.contractor_id = m.contractor_id and cc.store_removed_at is null) then
    side := 'contractor'; con := m.contractor_id;
  else raise exception 'You don''t have permission to manage maintenance plans here.'; end if;
  if old.id is not null and (old.customer_id <> cust or (side = 'contractor' and old.contractor_id <> m.contractor_id)) then raise exception 'Not allowed.'; end if;
  if old.id is not null and side = 'contractor' and old.approval = 'accepted' then raise exception 'This plan is in force. Ask the store to change it.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if con is null or not exists (select 1 from customer_contractors where customer_id = cust and contractor_id = con and store_removed_at is null) then
    raise exception 'Pick one of your contractors.'; end if;
  if coalesce(length(trim(p_name)), 0) < 3 then raise exception 'Give the plan a name, e.g. "Quarterly refrigeration PM".'; end if;
  if p_frequency_months is null or p_frequency_months not between 1 and 24 then raise exception 'How often: every 1 to 24 months.'; end if;
  if p_next_due is null or p_next_due < current_date - 60 or p_next_due > current_date + 730 then raise exception 'Pick the next due date.'; end if;
  if p_expected_hours is not null and (p_expected_hours <= 0 or p_expected_hours > 200) then raise exception 'Expected hours don''t look right.'; end if;
  if coalesce(p_finish_within_days, 2) not between 1 and 30 then raise exception 'Finish within 1 to 30 days of starting.'; end if;
  if p_price is not null and (p_price < 0 or p_price > 100000) then raise exception 'Price doesn''t look right.'; end if;
  if p_equipment is not null and not exists (select 1 from equipment where id = p_equipment and site_id = p_site) then raise exception 'That unit isn''t at this location.'; end if;
  for it in select * from jsonb_array_elements(case when jsonb_typeof(p_checklist) = 'array' then p_checklist else '[]' end) loop
    if length(trim(coalesce(it->>'item', it #>> '{}', ''))) >= 2 then
      cl := cl || jsonb_build_object('item', left(trim(coalesce(it->>'item', it #>> '{}')), 120), 'photo', coalesce((it->>'photo')::boolean, false), 'required', true);
    end if;
  end loop;
  if jsonb_array_length(cl) > 60 then raise exception 'Up to 60 checklist items.'; end if;

  if old.id is null then
    insert into pm_plans (contractor_id, customer_id, site_id, equipment_id, trade_id, name, frequency_months, checklist, price, lead_days,
                          next_due_on, active, expected_hours, finish_within_days, same_tech, approval, proposed_side, created_by)
    values (con, cust, p_site, p_equipment, p_trade, trim(p_name), p_frequency_months, cl, p_price, coalesce(p_lead_days, 14),
            p_next_due, coalesce(p_active, true), p_expected_hours, coalesce(p_finish_within_days, 2), coalesce(p_same_tech, true),
            case when side = 'store' then 'accepted' else 'proposed' end, side, m.id)
    returning id into nid;
  else
    update pm_plans set contractor_id = con, equipment_id = p_equipment, trade_id = p_trade, name = trim(p_name), frequency_months = p_frequency_months,
           checklist = cl, price = p_price, lead_days = coalesce(p_lead_days, 14), next_due_on = p_next_due, active = coalesce(p_active, true),
           expected_hours = p_expected_hours, finish_within_days = coalesce(p_finish_within_days, 2), same_tech = coalesce(p_same_tech, true),
           approval = case when side = 'store' then 'accepted' else 'proposed' end, proposed_side = side, decided_note = null, updated_at = now()
     where id = old.id returning id into nid;
  end if;
  if side = 'contractor' then
    perform _notify(p.id, null, 'approval_request', format('%s proposed a maintenance plan for %s: %s, every %s month%s, next due %s. Review it under Maintenance plans.',
        (select name from contractors where id = con), s.name, trim(p_name), p_frequency_months, case when p_frequency_months = 1 then '' else 's' end, to_char(p_next_due, 'Mon DD, YYYY')))
      from profiles p where p.customer_id = cust and p.active and (p.is_org_admin or p.can_manage_equipment or p.can_manage_pm);
  else
    perform _notify(p.id, null, 'pm_due', format('%s set a maintenance plan with you at %s: %s, every %s month%s, next due %s.',
        (select name from customers where id = cust), s.name, trim(p_name), p_frequency_months, case when p_frequency_months = 1 then '' else 's' end, to_char(p_next_due, 'Mon DD, YYYY')))
      from profiles p where p.contractor_id = con and p.active and (p.is_org_admin or p.can_dispatch);
  end if;
  return jsonb_build_object('ok', true, 'id', nid, 'approval', case when side = 'store' then 'accepted' else 'proposed' end);
end $$;
revoke execute on function save_pm_plan(uuid, uuid, uuid, text, int, date, jsonb, numeric, numeric, int, boolean, uuid, smallint, int, boolean) from public, anon;
grant execute on function save_pm_plan(uuid, uuid, uuid, text, int, date, jsonb, numeric, numeric, int, boolean, uuid, smallint, int, boolean) to authenticated;

create or replace function decide_pm_plan(p_id uuid, p_accept boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); p pm_plans;
begin
  select * into p from pm_plans where id = p_id for update;
  if p.id is null or p.approval <> 'proposed' then raise exception 'That plan isn''t waiting for a decision.'; end if;
  if not (m.customer_id = p.customer_id and store_can(p.customer_id, 'equipment')) then raise exception 'You don''t have permission to manage maintenance plans.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if not p_accept and coalesce(length(trim(p_note)), 0) < 3 then raise exception 'Say why, so the contractor knows.'; end if;
  update pm_plans set approval = case when p_accept then 'accepted' else 'declined' end, decided_note = nullif(trim(p_note), ''), updated_at = now() where id = p_id;
  perform _notify(pr.id, null, case when p_accept then 'approval_granted' else 'approval_declined' end::notify_type,
      case when p_accept then format('%s accepted your maintenance plan: %s.', (select name from customers where id = p.customer_id), p.name)
           else format('%s didn''t accept your maintenance plan %s: %s', (select name from customers where id = p.customer_id), p.name, trim(p_note)) end)
    from profiles pr where pr.contractor_id = p.contractor_id and pr.active and (pr.is_org_admin or pr.can_dispatch);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function decide_pm_plan(uuid, boolean, text) from public, anon;
grant execute on function decide_pm_plan(uuid, boolean, text) to authenticated;

-- PM calls: only accepted plans; follow the contractor's mode (Time Verify: plan price = PO limit, light bill).
-- Also each morning: flag PMs that drag past their window or change technicians, once each.
create or replace function pm_generate(p_today date default current_date) returns int
language plpgsql security definer set search_path = public as $$
declare p pm_plans; w work_orders; n int := 0; s sites; cov record; flat numeric; md text; pg jsonb;
begin
  for p in select * from pm_plans pl where pl.active and pl.approval = 'accepted' and pl.next_due_on - pl.lead_days <= p_today
             and not exists (select 1 from work_orders x where x.pm_plan_id = pl.id
                             and x.status not in ('completed','invoiced','cancelled')) loop
    select * into s from sites where id = p.site_id;
    md := coalesce((select cc.mode from customer_contractors cc where cc.customer_id = p.customer_id and cc.contractor_id = p.contractor_id), 'full');
    insert into work_orders (kind, contractor_id, customer_id, site_id, equipment_id, trade_id, agreement_id, pm_plan_id,
                             priority, issue_description, checklist, due_on, require_checkin, require_checkout, mode, nte)
    values ('pm', p.contractor_id, p.customer_id, p.site_id, p.equipment_id, p.trade_id,
            coalesce(p.agreement_id, (active_agreement(p.contractor_id, p.site_id)).id), p.id, 3,
            p.name || ' — due ' || to_char(p.next_due_on, 'Mon DD, YYYY'), p.checklist, p.next_due_on,
            s.require_checkin, s.require_checkout, md, case when md = 'verify' then p.price end)
    returning * into w;
    if md <> 'verify' then
      select * into cov from _coverage(w.id);
      flat := case when cov.pm then 0 else coalesce(p.price, 0) end;
      perform _allow_internal();
      update work_orders set flat_amount = flat where id = w.id;
      perform _end_internal();
      if p.price is not null or cov.pm then
        insert into po_lines (work_order_id, seq, kind, amount, description, status, decided_at)
        values (w.id, 0, 'pm', flat, case when cov.pm then 'PM visit — covered by agreement' else 'PM visit (flat price)' end,
                'approved', now());
      end if;
    end if;
    perform _notify_customer(w.id, 'pm_due', format('PM scheduled: %s at %s, due %s.', p.name, s.name, to_char(p.next_due_on, 'Mon DD')));
    perform _notify_office(w.id, 'pm_due', format('PM #%s created: %s at %s, due %s. Schedule the trip%s.',
      w.number, p.name, s.name, to_char(p.next_due_on, 'Mon DD'),
      case when p.expected_hours is not null then format(' (about %s h; finish within %s day%s of starting)', trim_scale(p.expected_hours), p.finish_within_days, case when p.finish_within_days = 1 then '' else 's' end) else '' end));
    n := n + 1;
  end loop;
  for w in select * from work_orders where kind = 'pm' and status not in ('completed','invoiced','cancelled') and due_on < p_today loop
    perform _notify_customer(w.id, 'pm_overdue', format('PM OVERDUE %s days: call #%s — %s.', p_today - w.due_on, w.number, w.issue_description),
      'pm_overdue:' || w.id || ':' || to_char(p_today, 'IYYY-IW'));
    perform _notify_office(w.id, 'pm_overdue', format('PM OVERDUE %s days: #%s — %s.', p_today - w.due_on, w.number, w.issue_description),
      'pm_overdue:' || w.id || ':' || to_char(p_today, 'IYYY-IW'));
  end loop;
  -- Started PMs: dragging past their window, or a different technician
  for w in select * from work_orders where kind = 'pm' and pm_plan_id is not null and status not in ('invoiced','cancelled')
             and exists (select 1 from visits v where v.work_order_id = work_orders.id and v.arrived_at is not null)
             and coalesce(completed_at, now()) > now() - interval '30 days' loop
    pg := _pm_progress(w.id);
    if (pg->>'dragging')::boolean then
      perform _raise_flag(w.id, 'pm_dragging', format('PM #%s started %s and was to be finished within %s day%s (by %s). %s trip%s so far%s.',
        w.number, to_char((pg->>'started')::timestamptz, 'Mon DD'), pg->>'finish_within_days', case when (pg->>'finish_within_days')::int = 1 then '' else 's' end,
        to_char((pg->>'deadline')::date, 'Mon DD'), pg->>'trips', case when (pg->>'trips')::int = 1 then '' else 's' end,
        case when (pg->>'done')::boolean then format(', finished %s', to_char((pg->>'completed')::timestamptz, 'Mon DD')) else ', not finished yet' end), false, true);
    end if;
    if (pg->>'tech_changed')::boolean then
      perform _raise_flag(w.id, 'pm_tech_changed', format('PM #%s: %s technicians so far (%s). This plan asks for the same technician start to finish.',
        w.number, pg->>'techs', pg->>'tech_names'), false, true);
    end if;
  end loop;
  return n;
end $$;

-- ---------- Pilot contractors ----------
create table if not exists pilot_interest (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  profile_id  uuid references profiles(id),
  company     text not null,
  name        text not null,
  email       text,
  phone       text,
  techs       int,
  plan        text,
  note        text,
  source      text not null default 'app' check (source in ('app','demo'))
);
alter table pilot_interest enable row level security;

create or replace function pilot_signup(p_company text, p_name text, p_email text, p_phone text, p_techs int, p_plan text, p_note text, p_source text default 'app')
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles; uid uuid := auth.uid();
begin
  if uid is not null then select * into m from profiles where id = uid; end if;
  if coalesce(length(trim(p_company)), 0) < 2 or coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter your company and your name.'; end if;
  if nullif(trim(p_email), '') is null and nullif(trim(p_phone), '') is null then raise exception 'Enter an email or a phone number so we can reach you.'; end if;
  if nullif(trim(p_email), '') is not null and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address.'; end if;
  if length(coalesce(p_note, '')) > 1000 or length(p_company) > 120 or length(p_name) > 120 then raise exception 'That''s a bit long. Please shorten it.'; end if;
  if (select count(*) from pilot_interest where created_at > now() - interval '1 hour') >= 30 then raise exception 'Please try again in a little while.'; end if;
  insert into pilot_interest (profile_id, company, name, email, phone, techs, plan, note, source)
  values (m.id, trim(p_company), trim(p_name), nullif(lower(trim(p_email)), ''), nullif(trim(p_phone), ''), case when p_techs between 1 and 1000 then p_techs end,
          case when p_plan in ('base','pro','enterprise') then p_plan end, nullif(trim(p_note), ''), case when p_source = 'demo' then 'demo' else 'app' end);
  perform _notify(a.id, null, 'guardrail_flag', format('Pilot interest: %s (%s), %s tech%s, %s. %s', trim(p_company), trim(p_name),
      coalesce(p_techs::text, '?'), case when p_techs = 1 then '' else 's' end, coalesce(initcap(p_plan), 'any plan'),
      concat_ws(' · ', nullif(trim(p_email), ''), nullif(trim(p_phone), ''))))
    from profiles a where a.is_platform_admin and a.active;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function pilot_signup(text, text, text, text, int, text, text, text) from public;
grant execute on function pilot_signup(text, text, text, text, int, text, text, text) to anon, authenticated;
