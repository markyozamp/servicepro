-- ServicePro 0008 — Property management companies, building-owner approval, one-off homeowners.
--
-- * A property manager is a customer type (like a grocery chain). Each property is residential or commercial.
-- * A property can have an OWNER (who is not a login). Above the owner's dollar limit, a PO letter the manager
--   approves then waits for the owner. The owner answers from a no-login link, or the manager records the
--   owner's answer given by phone. Emergencies: the manager approves and the owner is told afterwards.
-- * One-off homeowners never log in: the contractor's office opens the call with their name and phone, and the
--   homeowner approves a quote from the same kind of no-login link (or the office records a phone approval).

alter type customer_kind add value if not exists 'property_manager';

create table property_owners (
  id                    uuid primary key default gen_random_uuid(),
  customer_id           uuid not null references customers(id) on delete cascade,   -- the management company
  name                  text not null,
  phone                 text,
  email                 text,
  approval_above        numeric(10,2),   -- owner approves when a call's approved total would go above this; null = never
  response_hours        int not null default 24 check (response_hours between 1 and 168),
  notes                 text,
  created_at            timestamptz not null default now()
);
create index on property_owners (customer_id);

alter table sites
  add column property_type        text check (property_type in ('residential','commercial')),  -- null = the customer's kind
  add column owner_id             uuid references property_owners(id),
  add column owner_approval_above numeric(10,2);   -- overrides the owner's limit for this property

alter table work_orders
  add column unit          text,    -- apartment / suite
  add column contact_name  text,    -- who to meet: tenant, super, homeowner
  add column contact_phone text,
  add column entry_notes   text;

alter table po_lines
  add column owner_id            uuid references property_owners(id),
  add column owner_status        text check (owner_status in ('pending','approved','declined','emergency')),
  add column owner_requested_at  timestamptz,
  add column owner_decided_at    timestamptz,
  add column owner_decided_via   text check (owner_decided_via in ('link','phone')),
  add column owner_note          text,
  add column owner_recorded_by   uuid references profiles(id),
  add column manager_approved_by uuid references profiles(id),
  add column manager_approved_at timestamptz,
  add column customer_decided_via text check (customer_decided_via in ('link','phone'));  -- homeowner without a login

-- No-login approval links (owner or homeowner). Kept apart from po_lines so the contractor never sees an owner's link.
create table approval_links (
  token        uuid primary key default gen_random_uuid(),
  po_line_id   uuid not null references po_lines(id) on delete cascade,
  audience     text not null check (audience in ('owner','homeowner')),
  created_by   uuid references profiles(id),
  created_at   timestamptz not null default now(),
  used_at      timestamptz,
  used_from    text,                    -- IP / browser of the person who answered
  unique (po_line_id, audience)
);

-- ---------- Helpers ------------------------------------------------------
create or replace function _owner_rule(p_wo uuid)
returns table (owner_id uuid, owner_name text, limit_amount numeric, response_hours int)
language sql stable security definer set search_path = public as $$
  select o.id, o.name, coalesce(s.owner_approval_above, o.approval_above), o.response_hours
  from work_orders w join sites s on s.id = w.site_id join property_owners o on o.id = s.owner_id
  where w.id = p_wo
$$;

create or replace function _customer_has_logins(p_customer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where customer_id = p_customer and active)
$$;

create or replace function _request_from() returns text
language sql stable set search_path = public as $$
  select left(concat_ws(' · ',
    nullif(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1), ''),
    current_setting('request.headers', true)::json ->> 'user-agent'), 300)
$$;

-- The final yes/no on a PO letter, whoever gave it. Was the tail of decide_po_line.
create or replace function _finalize_po_line(p_line uuid, p_approve boolean, p_by uuid, p_limit numeric,
  p_reason text, p_who text) returns po_lines
language plpgsql security definer set search_path = public as $$
declare l po_lines; w work_orders; tech uuid;
begin
  update po_lines set status = case when p_approve then 'approved'::approval_status else 'declined' end,
         decided_by = p_by, decided_at = now(), decided_limit = p_limit,
         decline_reason = case when not p_approve then nullif(trim(p_reason), '') end
   where id = p_line returning * into l;
  select * into w from work_orders where id = l.work_order_id;
  perform _set_status(w.id, case
    when exists (select 1 from visits where work_order_id = w.id and status = 'on_site') then 'on_site'::wo_status
    when w.status = 'awaiting_approval' then 'return_needed'::wo_status
    else w.status end);
  if p_approve then
    update guardrail_flags set resolved_at = now(), resolved_by = p_by, resolution_note = 'Customer approved ' || po_label(w.id, l.seq)
     where work_order_id = w.id and flag in ('po_exceeded','po_near_cap') and resolved_at is null;
  end if;
  select technician_id into tech from visits where work_order_id = w.id and status = 'on_site' limit 1;
  perform _notify(tech, w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Call #%s: %s %s ($%s).', w.number, po_label(w.id, l.seq), case when p_approve then 'APPROVED' else 'DECLINED' end, l.amount));
  perform _notify_office(w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Call #%s: %s %s by %s ($%s)%s.', w.number, po_label(w.id, l.seq), case when p_approve then 'approved' else 'declined' end,
      p_who, l.amount, case when not p_approve and nullif(trim(p_reason), '') is not null then ': ' || trim(p_reason) else '' end));
  perform _notify_customer(w.id, case when p_approve then 'approval_granted'::notify_type else 'approval_declined' end,
    format('Call #%s: %s %s by %s ($%s).', w.number, po_label(w.id, l.seq), case when p_approve then 'approved' else 'declined' end,
      p_who, l.amount), 'po_final:' || l.id);
  return l;
end $$;

-- ---------- Approving: manager, then owner if needed -----------------------
create or replace function decide_po_line(p_line uuid, p_approve boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); l po_lines; w work_orders; total numeric; my_step int; nxt int; o record;
begin
  select * into l from po_lines where id = p_line for update;
  select * into w from work_orders where id = l.work_order_id for update;
  if m.customer_id is distinct from w.customer_id or not m.can_approve or not profile_sees_site(m.id, w.site_id) then
    raise exception 'You are not set up to approve spending for this location.';
  end if;
  if l.status <> 'pending' then raise exception 'Already decided.'; end if;
  if l.owner_status = 'pending' then
    raise exception 'You already approved this; it is waiting on the owner. Send them the approval link or record their answer.';
  end if;
  total := _total_with(l.id);
  if p_approve and m.approval_limit is not null and total > m.approval_limit then
    select max(s.step_no) into my_step from approval_chain_steps s join approval_chains c on c.id = s.chain_id
     where c.customer_id = w.customer_id and (s.profile_id = m.id or s.backup_profile_id = m.id);
    nxt := _route_po_line(l.id, greatest(coalesce(my_step, 0), coalesce(l.routed_step, 0)) + 1);
    return jsonb_build_object('ok', false, 'escalated', true,
      'message', format('This brings the call to $%s, above your $%s limit. It has been sent up for approval.', total, m.approval_limit));
  end if;

  if p_approve then
    select * into o from _owner_rule(w.id);
    if o.owner_id is not null and o.limit_amount is not null and total > o.limit_amount then
      if w.priority = 1 then
        -- Emergency: the manager's approval stands; the owner is told afterwards.
        update po_lines set owner_id = o.owner_id, owner_status = 'emergency', owner_requested_at = now(),
               manager_approved_by = m.id, manager_approved_at = now() where id = l.id;
        perform _notify_customer(w.id, 'approval_granted', format(
          'Call #%s: emergency repair %s ($%s) approved by %s without waiting for the owner. Let %s know — the call total is now $%s, above their $%s limit.',
          w.number, po_label(w.id, l.seq), l.amount, m.full_name, o.owner_name, total, o.limit_amount), 'owner_emergency:' || l.id);
      else
        update po_lines set owner_id = o.owner_id, owner_status = 'pending', owner_requested_at = now(),
               manager_approved_by = m.id, manager_approved_at = now(), routed_step = null where id = l.id;
        insert into approval_links (po_line_id, audience, created_by) values (l.id, 'owner', m.id) on conflict do nothing;
        perform _notify_office(w.id, 'approval_request', format(
          'Call #%s: %s ($%s) approved by %s — now waiting on the building owner''s approval.', w.number, po_label(w.id, l.seq), l.amount, m.full_name));
        return jsonb_build_object('ok', false, 'owner_pending', true, 'message', format(
          'Approved by you. The call total would be $%s, above the owner''s $%s limit, so it now needs %s''s OK. Send them the approval link, or record their answer if they told you by phone.',
          total, o.limit_amount, o.owner_name));
      end if;
    end if;
  end if;

  l := _finalize_po_line(l.id, p_approve, m.id, m.approval_limit, p_reason, m.full_name);
  return jsonb_build_object('ok', true, 'status', l.status);
end $$;

-- A link for the owner (from the manager) or for a homeowner with no login (from the contractor office).
create or replace function approval_link(p_line uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); l po_lines; w work_orders; tok uuid;
begin
  select * into l from po_lines where id = p_line;
  select * into w from work_orders where id = l.work_order_id;
  if l.id is null or l.status <> 'pending' then raise exception 'This request is not waiting on anyone.'; end if;
  if l.owner_status = 'pending' then
    if m.customer_id is distinct from w.customer_id or not m.can_approve or not profile_sees_site(m.id, w.site_id) then
      raise exception 'Only the property manager''s approvers can send the owner link.';
    end if;
    insert into approval_links (po_line_id, audience, created_by) values (l.id, 'owner', m.id)
      on conflict (po_line_id, audience) do update set created_by = approval_links.created_by
      returning token into tok;
  else
    if not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
    if _customer_has_logins(w.customer_id) then
      raise exception 'This customer approves in their own portal.';
    end if;
    insert into approval_links (po_line_id, audience, created_by) values (l.id, 'homeowner', m.id)
      on conflict (po_line_id, audience) do update set created_by = approval_links.created_by
      returning token into tok;
  end if;
  return tok;
end $$;

-- What the person opening the link sees. Callable without signing in; the token is the key.
create or replace function link_quote(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'audience', k.audience,
    'state', case when l.status <> 'pending' then l.status::text
                  when k.audience = 'owner' and l.owner_status <> 'pending' then l.owner_status
                  else 'pending' end,
    'call_number', w.number, 'po', po_label(w.id, l.seq), 'amount', l.amount, 'description', l.description,
    'breakdown', l.breakdown, 'problem', w.issue_description,
    'property', s.name, 'address', s.address, 'unit', w.unit,
    'contractor', c.name, 'contractor_phone', c.phone, 'customer', cu.name,
    'owner', o.name, 'manager', mp.full_name, 'manager_approved_at', l.manager_approved_at,
    'approved_so_far', (select coalesce(sum(amount), 0) from po_lines x where x.work_order_id = w.id and x.status = 'approved'),
    'total_if_approved', _total_with(l.id),
    'owner_limit', (select limit_amount from _owner_rule(w.id)),
    'photos', (select count(*) from photos p where p.work_order_id = w.id),
    'decided_at', coalesce(l.owner_decided_at, l.decided_at))
  from approval_links k join po_lines l on l.id = k.po_line_id join work_orders w on w.id = l.work_order_id
  join sites s on s.id = w.site_id join contractors c on c.id = w.contractor_id join customers cu on cu.id = w.customer_id
  left join property_owners o on o.id = l.owner_id left join profiles mp on mp.id = l.manager_approved_by
  where k.token = p_token
$$;

create or replace function _owner_answer(p_line uuid, p_approve boolean, p_note text, p_via text, p_recorded_by uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l po_lines; w work_orders; o property_owners; mgr profiles;
begin
  select * into l from po_lines where id = p_line for update;
  if l.status <> 'pending' or l.owner_status is distinct from 'pending' then raise exception 'This was already answered.'; end if;
  select * into w from work_orders where id = l.work_order_id for update;
  select * into o from property_owners where id = l.owner_id;
  select * into mgr from profiles where id = l.manager_approved_by;
  update po_lines set owner_status = case when p_approve then 'approved' else 'declined' end, owner_decided_at = now(),
         owner_decided_via = p_via, owner_note = nullif(trim(p_note), ''), owner_recorded_by = p_recorded_by
   where id = l.id;
  perform _finalize_po_line(l.id, p_approve, l.manager_approved_by, mgr.approval_limit,
    case when not p_approve then 'Owner declined' || coalesce(': ' || nullif(trim(p_note), ''), '') end,
    format('owner %s%s', o.name, case when p_via = 'phone' then ' (by phone)' else '' end));
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'declined' end);
end $$;

create or replace function link_decide(p_token uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k approval_links; l po_lines; w work_orders; cu customers; r jsonb;
begin
  select * into k from approval_links where token = p_token for update;
  if k.token is null then raise exception 'This link is not valid.'; end if;
  select * into l from po_lines where id = k.po_line_id;
  if l.status <> 'pending' then return jsonb_build_object('ok', true, 'already', true, 'status', l.status); end if;
  if not p_approve and coalesce(length(trim(p_note)), 0) < 3 then raise exception 'Please say why, so the contractor knows.'; end if;
  update approval_links set used_at = now(), used_from = _request_from() where token = k.token;
  if k.audience = 'owner' then
    return _owner_answer(l.id, p_approve, p_note, 'link', null);
  end if;
  select * into w from work_orders where id = l.work_order_id;
  select * into cu from customers where id = w.customer_id;
  update po_lines set customer_decided_via = 'link' where id = l.id;
  l := _finalize_po_line(l.id, p_approve, null, null, p_note, coalesce(w.contact_name, cu.name) || ' (by link)');
  return jsonb_build_object('ok', true, 'status', l.status);
end $$;

-- The owner (or a homeowner) answered by phone; someone records it, with a note. Logged.
create or replace function record_phone_approval(p_line uuid, p_approve boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); l po_lines; w work_orders; cu customers;
begin
  select * into l from po_lines where id = p_line;
  select * into w from work_orders where id = l.work_order_id;
  if l.id is null or l.status <> 'pending' then raise exception 'This request is not waiting on anyone.'; end if;
  if coalesce(length(trim(p_note)), 0) < 5 then raise exception 'Note who you spoke to and when (e.g. "Owner OK''d by phone 2:10 pm").'; end if;
  if l.owner_status = 'pending' then
    if m.customer_id is distinct from w.customer_id or not m.can_approve or not profile_sees_site(m.id, w.site_id) then
      raise exception 'Only the property manager''s approvers can record the owner''s answer.';
    end if;
    return _owner_answer(l.id, p_approve, p_note, 'phone', m.id);
  end if;
  if not is_contractor_office(w.contractor_id) or _customer_has_logins(w.customer_id) then
    raise exception 'Not allowed — this customer approves in their own portal.';
  end if;
  select * into cu from customers where id = w.customer_id;
  update po_lines set customer_decided_via = 'phone' where id = l.id;
  l := _finalize_po_line(l.id, p_approve, null, null, p_note,
         format('%s by phone (recorded by %s: %s)', coalesce(w.contact_name, cu.name), m.full_name, trim(p_note)));
  return jsonb_build_object('ok', true, 'status', l.status);
end $$;

-- Reminders: approvals stuck on an owner past their response time remind the manager once a day.
create or replace function escalate_stale_approvals() returns int
language plpgsql security definer set search_path = public as $$
declare l record; n int := 0; c approval_chains; last_step int; w work_orders;
begin
  for l in select pl.* from po_lines pl where pl.status = 'pending' and pl.routed_step is not null
             and pl.owner_status is distinct from 'pending' loop
    c := _chain_for(l.work_order_id);
    if c.id is null or l.routed_at > now() - make_interval(mins => c.timeout_minutes) then continue; end if;
    select max(step_no) into last_step from approval_chain_steps where chain_id = c.id;
    if l.routed_step >= last_step then continue; end if;
    perform _route_po_line(l.id, l.routed_step + 1);
    n := n + 1;
  end loop;
  for l in select pl.*, o.name owner_name, o.response_hours from po_lines pl join property_owners o on o.id = pl.owner_id
            where pl.status = 'pending' and pl.owner_status = 'pending'
              and pl.owner_requested_at < now() - make_interval(hours => o.response_hours) loop
    select * into w from work_orders where id = l.work_order_id;
    perform _notify(p.id, w.id, 'approval_request', format(
      'Call #%s: still waiting on %s to approve %s ($%s). Call them, or record their answer.',
      w.number, l.owner_name, po_label(w.id, l.seq), l.amount), 'owner_wait:' || l.id || ':' || current_date)
    from profiles p where p.customer_id = w.customer_id and p.active and p.can_approve and profile_sees_site(p.id, w.site_id);
    perform _notify_office(w.id, 'approval_request', format('Call #%s: still waiting on the building owner for %s.',
      w.number, po_label(w.id, l.seq)), 'owner_wait:' || l.id || ':' || current_date);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Setting up owners and properties (property manager admins) ----
create or replace function save_property_owner(p_id uuid, p_name text, p_phone text default null, p_email text default null,
  p_approval_above numeric default null, p_response_hours int default 24, p_notes text default null)
returns property_owners language plpgsql security definer set search_path = public as $$
declare m profiles := me(); o property_owners;
begin
  if m.customer_id is null or not m.is_org_admin then raise exception 'Only your company''s admin can manage owners.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Owner name is required.'; end if;
  if p_id is null then
    insert into property_owners (customer_id, name, phone, email, approval_above, response_hours, notes)
    values (m.customer_id, trim(p_name), p_phone, p_email, p_approval_above, coalesce(p_response_hours, 24), p_notes) returning * into o;
  else
    update property_owners set name = trim(p_name), phone = p_phone, email = p_email, approval_above = p_approval_above,
           response_hours = coalesce(p_response_hours, 24), notes = p_notes
     where id = p_id and customer_id = m.customer_id returning * into o;
    if o.id is null then raise exception 'Unknown owner.'; end if;
  end if;
  return o;
end $$;

create or replace function set_site_owner(p_site uuid, p_owner uuid, p_property_type text default null,
  p_owner_approval_above numeric default null) returns sites
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not is_customer_admin(s.customer_id) then raise exception 'Only your company''s admin can change this.'; end if;
  if p_owner is not null and not exists (select 1 from property_owners where id = p_owner and customer_id = s.customer_id) then
    raise exception 'Unknown owner.';
  end if;
  update sites set owner_id = p_owner, property_type = p_property_type, owner_approval_above = p_owner_approval_above
   where id = p_site returning * into s;
  return s;
end $$;

-- ---------- Calls: unit and who to meet -----------------------------------
create or replace function set_call_contact(p_wo uuid, p_unit text default null, p_contact_name text default null,
  p_contact_phone text default null, p_entry_notes text default null) returns work_orders
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if not (is_contractor_dispatcher(w.contractor_id)
          or (m.customer_id = w.customer_id and (m.can_open_calls or m.is_org_admin) and profile_sees_site(m.id, w.site_id))) then
    raise exception 'Not allowed.';
  end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'This call is closed.'; end if;
  perform _allow_internal();
  update work_orders set unit = nullif(trim(p_unit), ''), contact_name = nullif(trim(p_contact_name), ''),
         contact_phone = nullif(trim(p_contact_phone), ''), entry_notes = nullif(trim(p_entry_notes), '')
   where id = p_wo returning * into w;
  perform _end_internal();
  return w;
end $$;

-- ---------- One-off homeowner: the office adds them in one step -------------
create or replace function quick_customer(p_name text, p_address text, p_zip text default null,
  p_phone text default null, p_email text default null, p_access_notes text default null)
returns sites language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cu customers; s sites; tz text;
begin
  if m.contractor_id is null or not is_contractor_dispatcher(m.contractor_id) then raise exception 'Only dispatch can add customers.'; end if;
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_address), '') = '' then raise exception 'Name and address are required.'; end if;
  select timezone into tz from contractors where id = m.contractor_id;
  insert into customers (name, kind, phone, email) values (trim(p_name), 'residential', p_phone, p_email) returning * into cu;
  insert into customer_contractors (contractor_id, customer_id) values (m.contractor_id, cu.id);
  insert into sites (customer_id, name, address, zip, access_notes, timezone)
  values (cu.id, 'Home', trim(p_address), nullif(trim(p_zip), ''), p_access_notes, coalesce(tz, 'America/Chicago')) returning * into s;
  return s;
end $$;

-- ---------- Fees: property managers pay like stores; one-off homeowners pay nothing
create or replace function _record_fees(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; cu customers; c contractors; ps platform_settings; mon date; tech uuid;
begin
  select * into w from work_orders where id = p_wo;
  select * into cu from customers where id = w.customer_id;
  select * into c from contractors where id = w.contractor_id;
  select * into ps from platform_settings;
  mon := date_trunc('month', w.completed_at)::date;
  select technician_id into tech from visits where work_order_id = p_wo and status = 'done' order by visit_no desc limit 1;
  if cu.kind <> 'residential' then   -- homeowners pay nothing
    insert into platform_fees (org_kind, org_id, work_order_id, billing_month, amount, waived)
    values ('customer', cu.id, p_wo, mon, case when w.kind = 'pm' then ps.store_fee_per_pm else ps.store_fee_per_po end,
            coalesce(cu.fees_waived_until >= w.completed_at::date, false))
    on conflict do nothing;
  end if;
  insert into platform_fees (org_kind, org_id, work_order_id, technician_id, billing_month, amount, waived)
  values ('contractor', c.id, p_wo, tech, mon, case when w.kind = 'pm' then ps.contractor_fee_per_pm else ps.contractor_fee_per_po end,
          coalesce(c.fees_waived_until >= w.completed_at::date, false))
  on conflict do nothing;
end $$;

-- ---------- Security --------------------------------------------------------
alter table property_owners enable row level security;
alter table approval_links enable row level security;
-- New tables otherwise inherit Supabase's default "all privileges" (TRUNCATE ignores row-level security).
revoke all on property_owners, approval_links from authenticated, anon;
alter default privileges in schema public revoke all on tables from authenticated;
grant select on property_owners, approval_links to authenticated;
grant insert (customer_id, property_type, owner_id, owner_approval_above),
      update (property_type, owner_id, owner_approval_above) on sites to authenticated;
create policy read_owners on property_owners for select using (is_platform_admin() or is_customer_member(customer_id)
  or exists (select 1 from customer_contractors cc where cc.customer_id = property_owners.customer_id and is_contractor_member(cc.contractor_id)));
-- Links: the manager's approvers see owner links; the contractor office sees homeowner links only.
create policy read_links on approval_links for select using (exists (
  select 1 from po_lines l join work_orders w on w.id = l.work_order_id where l.id = po_line_id and (
    (audience = 'owner' and is_customer_member(w.customer_id) and can_see_site(w.site_id))
    or (audience = 'homeowner' and is_contractor_office(w.contractor_id)))));

do $$ declare f text; begin
  foreach f in array array['decide_po_line(uuid,boolean,text)', 'approval_link(uuid)', 'record_phone_approval(uuid,boolean,text)',
    'save_property_owner(uuid,text,text,text,numeric,integer,text)', 'set_site_owner(uuid,uuid,text,numeric)',
    'set_call_contact(uuid,text,text,text,text)', 'quick_customer(text,text,text,text,text,text)'] loop
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;
-- The no-login link page (the token is the only key)
grant usage on schema public to anon;
grant execute on function link_quote(uuid), link_decide(uuid,boolean,text) to anon, authenticated;
