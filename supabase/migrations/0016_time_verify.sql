-- =====================================================================
-- ServicePro 0016 — Time Verify: the simple entry offering.
-- The store pays a flat fee per location per month; the contractor uses it free.
--   * The store opens a call as a PO (its own number or ours), problem from the list, optional not-to-exceed.
--   * The right contractor for that trade at that store is alerted; the office accepts ("now" or a time window).
--     Not accepted in time → the store is told.
--   * Any of the contractor's techs taps "I'm going" (one tech per call, no double dispatch), "I'm here" (GPS),
--     enters the store's check-in code, and "Leaving" (done / coming back / waiting for parts). Photos optional.
--     "Parts run" records leaving the site, being at the supplier, and coming back.
--   * Calls the contractor took by phone are entered by the contractor and confirmed by the store.
--   * A QR sticker on each unit lets any store employee report a problem with the store PIN.
--   * The store can press "Tech is here" when a tech arrived but didn't tap "I'm here".
--   * The contractor enters the invoice (number, total, hours billed); the store sees billed vs verified hours.
--   * Sign-in by link (no password) for contractors and techs.
-- Calls of a "full" relationship work exactly as before.
-- =====================================================================

alter type flag_type add value if not exists 'call_unconfirmed';
alter type flag_type add value if not exists 'repeat_call';
alter type flag_type add value if not exists 'not_accepted';
alter type flag_type add value if not exists 'arrival_by_store';
alter type flag_type add value if not exists 'invoice_unexplained';
alter type flag_type add value if not exists 'invoice_over_nte';

-- ---------- Settings ---------------------------------------------------------
alter table platform_settings add column verify_fee_per_site numeric(10,2) not null default 25;

alter table customer_contractors
  add column mode                 text not null default 'full' check (mode in ('full','verify')),
  add column pays_travel          text not null default 'yes' check (pays_travel in ('yes','no','after_hours')),
  add column accept_emergency_min int  not null default 15  check (accept_emergency_min between 5 and 240),
  add column accept_normal_min    int  not null default 240 check (accept_normal_min between 15 and 4320),
  add column min_hours            numeric(4,2) not null default 1 check (min_hours between 0 and 8),   -- contractor's minimum per visit
  add column increment_min        int  not null default 15 check (increment_min in (1,5,6,10,15,30,60));

-- Which contractor gets which trade (site_id null = all of the store's locations)
create table trade_contractors (
  id            uuid primary key default gen_random_uuid(),
  customer_id   uuid not null references customers(id) on delete cascade,
  site_id       uuid references sites(id) on delete cascade,
  trade_id      smallint not null references trades(id),
  contractor_id uuid references contractors(id) on delete cascade,     -- null = use the store's primary contractor
  updated_at    timestamptz not null default now()
);
create unique index trade_contractors_site on trade_contractors (site_id, trade_id) where site_id is not null;
create unique index trade_contractors_all on trade_contractors (customer_id, trade_id) where site_id is null;

-- The store's PIN for reporting by QR sticker. Kept apart so no one can read the hash.
create table site_report_pins (
  site_id    uuid primary key references sites(id) on delete cascade,
  pin_hash   text not null,
  updated_at timestamptz not null default now()
);
create table qr_attempts (
  id     bigint generated always as identity primary key,
  token  uuid not null,
  at     timestamptz not null default now()
);
create index on qr_attempts (token, at);

alter table equipment add column qr_token uuid not null default gen_random_uuid();
create unique index equipment_qr_token on equipment (qr_token);

-- ---------- The call ---------------------------------------------------------
alter table work_orders
  add column mode               text not null default 'full' check (mode in ('full','verify')),
  add column source             text not null default 'store' check (source in ('store','contractor','qr','pm')),
  add column nte                numeric(10,2) check (nte is null or nte >= 0),   -- store's optional not-to-exceed
  add column reported_by_name   text,
  add column accept_due_at      timestamptz,
  add column accepted_at        timestamptz,
  add column accepted_by        uuid references profiles(id),
  add column accept_note        text,
  add column scheduled_start    timestamptz,
  add column scheduled_end      timestamptz,
  add column declined_at        timestamptz,
  add column decline_reason     text,
  add column store_confirmed_at timestamptz,
  add column store_confirmed_by uuid references profiles(id),
  add column store_disputed     boolean not null default false,
  add column store_seen_at      timestamptz,
  add column store_seen_by      uuid references profiles(id);
create index on work_orders (mode, status) where mode = 'verify';

alter table visits add column arrival_source text check (arrival_source in ('geofence','manual','store'));

create table parts_runs (
  id             uuid primary key default gen_random_uuid(),
  visit_id       uuid not null references visits(id) on delete cascade,
  work_order_id  uuid not null references work_orders(id) on delete cascade,
  technician_id  uuid not null references profiles(id),
  supplier       text,
  left_at        timestamptz not null,
  left_lat       double precision, left_lon double precision,
  at_supplier_at timestamptz,
  supplier_lat   double precision, supplier_lon double precision,
  returned_at    timestamptz,
  return_lat     double precision, return_lon double precision,
  created_at     timestamptz not null default now()
);
create index on parts_runs (visit_id);

create table call_invoices (
  work_order_id    uuid primary key references work_orders(id) on delete cascade,
  invoice_number   text not null,
  po_number        text,
  total            numeric(10,2) not null check (total >= 0),
  hours_billed     numeric(6,2) not null check (hours_billed >= 0),
  other_hours      numeric(6,2) not null default 0 check (other_hours >= 0),   -- shop work, etc.
  other_reason     text,
  other_photo_path text,                                                      -- job-photos/<wo>/<id>.jpg
  check_result     jsonb not null default '{}',
  entered_side     text not null check (entered_side in ('contractor','store')),
  entered_by       uuid references profiles(id),
  entered_at       timestamptz not null default now(),
  status           text not null default 'submitted' check (status in ('submitted','approved','disputed')),
  reviewed_by      uuid references profiles(id),
  reviewed_at      timestamptz,
  review_note      text
);

-- ---------- Sign-in links ----------------------------------------------------
create table join_links (
  token         uuid primary key default gen_random_uuid(),
  kind          text not null check (kind in ('contractor_owner','contractor_member','relink')),
  contractor_id uuid references contractors(id) on delete cascade,
  customer_id   uuid references customers(id) on delete cascade,   -- the store that invited the contractor
  profile_id    uuid references profiles(id) on delete cascade,    -- relink: an existing login on a new phone
  full_name     text,
  phone         text,
  email         text,
  perms         jsonb not null default '{}',
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '7 days',
  used_at       timestamptz
);

-- ---------- Alerts to phones (web push) and email ----------------------------
create table push_subscriptions (
  endpoint    text primary key,
  profile_id  uuid not null references profiles(id) on delete cascade,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now(),
  failed      int not null default 0
);
create table app_secrets (name text primary key, value text not null);
insert into app_secrets values ('outbox', encode(extensions.gen_random_bytes(24), 'hex')) on conflict do nothing;

-- ---------- Small helpers ----------------------------------------------------
create or replace function _cc(p_customer uuid, p_contractor uuid) returns customer_contractors
language sql stable security definer set search_path = public as $$
  select * from customer_contractors where customer_id = p_customer and contractor_id = p_contractor
$$;

-- The contractor for a trade at a location: site rule → store-wide rule → primary contractor.
create or replace function _route_contractor(p_site uuid, p_trade smallint) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select contractor_id from trade_contractors where site_id = p_site and trade_id = p_trade),
    (select tc.contractor_id from trade_contractors tc join sites s on s.customer_id = tc.customer_id
      where s.id = p_site and tc.site_id is null and tc.trade_id = p_trade),
    (select cc.contractor_id from customer_contractors cc join sites s on s.customer_id = cc.customer_id
      where s.id = p_site order by cc.is_primary desc, cc.created_at limit 1))
$$;

create or replace function _local(p_at timestamptz, p_site uuid, p_fmt text default 'Dy HH12:MI AM') returns text
language sql stable security definer set search_path = public as $$
  select to_char(p_at at time zone (select timezone from sites where id = p_site), p_fmt)
$$;

create or replace function _po(w work_orders) returns text
language sql immutable as $$ select coalesce(w.store_po_number, 'PO' || w.number) $$;

-- Same unit (or same location + problem when no unit) within 30 days
create or replace function _repeat_check(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; prev work_orders;
begin
  select * into w from work_orders where id = p_wo;
  select * into prev from work_orders x
   where x.id <> w.id and x.site_id = w.site_id and x.status <> 'cancelled' and x.kind <> 'pm'
     and x.created_at > w.created_at - interval '30 days' and x.created_at < w.created_at
     and ((w.equipment_id is not null and x.equipment_id = w.equipment_id)
       or (w.equipment_id is null and w.issue_type_id is not null and x.issue_type_id = w.issue_type_id))
   order by x.created_at desc limit 1;
  if prev.id is not null then
    perform _raise_flag(w.id, 'repeat_call', format('Repeat call: %s had call #%s on %s (%s).',
      case when w.equipment_id is not null then 'this unit' else 'this location, same problem,' end,
      prev.number, _local(prev.created_at, w.site_id, 'Mon DD'), prev.status), false, true);
  end if;
end $$;

-- ---------- Opening a call (one engine for store, contractor and QR sticker) ----------
create or replace function _create_call(
  p_site uuid, p_issue_type uuid, p_description text, p_equipment uuid, p_priority smallint,
  p_store_po_number text, p_kind wo_kind, p_contractor uuid, p_require_checkin boolean, p_id uuid,
  p_by uuid, p_side text, p_nte numeric default null, p_reporter text default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare
  s sites; cu customers; it issue_types; v_contractor uuid; a agreements; cc customer_contractors;
  w work_orders; v_amount numeric; v_after boolean; v_desc text; v_resp int; wr record; v_verify boolean;
  rep text; byname text;
begin
  select * into s from sites where id = p_site;
  if s.id is null then raise exception 'Unknown site.'; end if;
  select * into cu from customers where id = s.customer_id;
  if p_issue_type is not null then
    select * into it from issue_types where id = p_issue_type and active;
    if it.id is null then raise exception 'Unknown problem type.'; end if;
  end if;
  v_contractor := coalesce(p_contractor, case when it.trade_id is not null then _route_contractor(p_site, it.trade_id) end,
                           _route_contractor(p_site, null));
  cc := _cc(s.customer_id, v_contractor);
  if cc.contractor_id is null then raise exception 'That contractor does not serve this customer.'; end if;
  if p_equipment is not null and not exists (select 1 from equipment where id = p_equipment and site_id = p_site) then
    raise exception 'That equipment is not at this location.';
  end if;
  if p_nte is not null and p_nte < 0 then raise exception 'The not-to-exceed amount cannot be negative.'; end if;
  v_verify := cc.mode = 'verify' and p_kind <> 'pm';

  v_desc := coalesce(nullif(trim(p_description), ''), it.name);
  if v_desc is null then raise exception 'Describe the problem.'; end if;
  a := active_agreement(v_contractor, p_site);
  v_after := is_after_hours(p_site);
  v_amount := case when not v_verify and (it.id is not null or a.diagnosis_amount is not null)
                   then diagnosis_amount(p_site, it.id, v_contractor) end;

  insert into work_orders (id, kind, contractor_id, customer_id, site_id, equipment_id, trade_id, issue_type_id,
                           agreement_id, priority, after_hours, issue_description, store_po_number,
                           require_checkin, require_checkout, created_by, mode, source, nte, reported_by_name, contact_name)
  values (coalesce(p_id, gen_random_uuid()), p_kind, v_contractor, s.customer_id, p_site, p_equipment, it.trade_id, it.id,
          a.id, coalesce(p_priority, it.priority, 2), v_after, v_desc, nullif(trim(p_store_po_number), ''),
          coalesce(p_require_checkin, case when v_verify then true else s.require_checkin end), s.require_checkout, p_by,
          case when v_verify then 'verify' else 'full' end, p_side, case when v_verify then p_nte end,
          nullif(trim(p_reporter), ''), nullif(trim(p_reporter), ''))
  returning * into w;

  perform _allow_internal();
  -- Response-time commitment from the agreement
  v_resp := case w.priority when 1 then a.response_emergency_min when 2 then a.response_normal_min else a.response_low_min end;
  if v_resp is not null then
    update work_orders set response_due_at = created_at + make_interval(mins => v_resp) where id = w.id returning * into w;
  end if;
  if v_verify then
    update work_orders set
      accept_due_at = case when p_side = 'contractor' then null
                           else created_at + make_interval(mins => case when w.priority = 1 then cc.accept_emergency_min else cc.accept_normal_min end) end,
      accepted_at = case when p_side = 'contractor' then created_at end,
      accepted_by = case when p_side = 'contractor' then p_by end,
      store_confirmed_at = case when p_side = 'contractor' then null else created_at end,
      store_confirmed_by = case when p_side = 'store' then p_by end
    where id = w.id returning * into w;
  end if;
  perform _end_internal();

  -- PO base line (full mode): the diagnosis amount the store authorizes
  if v_amount is not null then
    insert into po_lines (work_order_id, seq, kind, amount, description, status, requested_by, decided_by, decided_at)
    values (w.id, 0, case p_kind when 'install' then 'install'::po_line_kind else 'diagnosis' end, v_amount,
            case when v_after then 'Diagnosis (after hours)' else 'Diagnosis' end ||
            case when p_side = 'contractor' then ' — entered by contractor' else '' end,
            'approved', p_by, case when p_side = 'store' then p_by end, now());
  end if;

  perform _repeat_check(w.id);
  rep := (select ' ' || description from guardrail_flags where work_order_id = w.id and flag = 'repeat_call' and resolved_at is null);
  byname := coalesce((select full_name from profiles where id = p_by), nullif(trim(p_reporter), ''));

  if p_side = 'contractor' then
    if v_verify then
      perform _raise_flag(w.id, 'call_unconfirmed', format('Entered by %s (contractor) — the store has not confirmed it yet.', byname), false, true);
      perform _notify_customer(w.id, 'new_call', format('%s entered call #%s (%s) at %s: %s%s. Please confirm you requested it.',
        (select name from contractors where id = v_contractor), w.number, _po(w), s.name, w.issue_description,
        case when w.contact_name is not null then ' — requested by ' || w.contact_name else '' end));
    else
      perform _notify_customer(w.id, 'new_call', format('%s opened call #%s at %s: %s',
        (select name from contractors where id = v_contractor), w.number, s.name, w.issue_description));
    end if;
  elsif v_verify then
    perform _notify_office(w.id, 'new_call', format('New %sPO call #%s (%s) at %s: %s%s. Please accept by %s.%s',
      case when w.priority = 1 then 'EMERGENCY ' else '' end, w.number, _po(w), s.name, w.issue_description,
      case when p_side = 'qr' then format(' (reported by %s via the unit''s QR sticker)', byname) else '' end,
      _local(w.accept_due_at, w.site_id, 'HH12:MI AM Dy'), coalesce(rep, '')));
  else
    perform _notify_office(w.id, 'new_call', format('New %scall #%s at %s: %s%s',
      case when w.priority = 1 then 'EMERGENCY ' else '' end, w.number, s.name, w.issue_description, coalesce(rep, '')));
  end if;

  -- Warranty heads-up for both sides
  if p_equipment is not null then
    for wr in select * from warranties where equipment_id = p_equipment and ends_on >= current_date loop
      perform _notify_customer(w.id, 'warranty', format('Call #%s: this unit has %s warranty until %s (%s).',
        w.number, wr.kind, to_char(wr.ends_on, 'Mon DD, YYYY'), wr.description), 'warranty:' || w.id || ':' || wr.id);
      perform _notify_office(w.id, 'warranty', format('Call #%s: unit under %s warranty until %s (%s).',
        w.number, wr.kind, to_char(wr.ends_on, 'Mon DD, YYYY'), wr.description), 'warranty:' || w.id || ':' || wr.id);
    end loop;
  end if;
  select * into w from work_orders where id = w.id;
  return w;
end $$;

-- Same call as before (store or contractor office); now routes by trade and knows Time Verify.
create or replace function create_work_order(
  p_site uuid, p_issue_type uuid default null, p_description text default null, p_equipment uuid default null,
  p_priority smallint default null, p_store_po_number text default null, p_kind wo_kind default 'service',
  p_contractor uuid default null, p_require_checkin boolean default null, p_id uuid default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites;
begin
  if m.id is null then raise exception 'Not signed in.'; end if;
  select * into s from sites where id = p_site;
  if s.id is null then raise exception 'Unknown site.'; end if;
  if p_id is not null and exists (select 1 from work_orders where id = p_id) then   -- sent twice
    return (select w from work_orders w where w.id = p_id and can_see_work_order(w.id));
  end if;
  if m.customer_id is not null then
    if m.customer_id <> s.customer_id or not profile_sees_site(m.id, p_site) then raise exception 'That location is not yours.'; end if;
    if not (m.can_open_calls or m.is_org_admin) then raise exception 'You are not set up to open service calls.'; end if;
    if p_kind = 'service' and p_issue_type is null then raise exception 'Pick what the problem is from the list.'; end if;
    return _create_call(p_site, p_issue_type, p_description, p_equipment, p_priority, p_store_po_number, p_kind,
                        p_contractor, p_require_checkin, p_id, m.id, 'store');
  elsif m.contractor_id is not null and (m.is_org_admin or m.can_dispatch) then
    if not exists (select 1 from customer_contractors where contractor_id = m.contractor_id and customer_id = s.customer_id) then
      raise exception 'That contractor does not serve this customer.';
    end if;
    return _create_call(p_site, p_issue_type, p_description, p_equipment, p_priority, p_store_po_number, p_kind,
                        m.contractor_id, p_require_checkin, p_id, m.id, 'contractor');
  end if;
  raise exception 'Your role cannot open service calls.';
end $$;

-- Store: open a call as a PO (Time Verify screen). PO number optional (else PO + call number), NTE optional.
create or replace function open_po_call(p_site uuid, p_issue_type uuid, p_details text default null,
  p_po_number text default null, p_nte numeric default null, p_priority smallint default null,
  p_equipment uuid default null, p_contractor uuid default null, p_unit text default null, p_id uuid default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; w work_orders;
begin
  if p_id is not null and exists (select 1 from work_orders where id = p_id) then
    return (select x from work_orders x where x.id = p_id and can_see_work_order(x.id));
  end if;
  select * into s from sites where id = p_site;
  if m.customer_id is null or s.customer_id is distinct from m.customer_id or not profile_sees_site(m.id, p_site) then
    raise exception 'That location is not yours.';
  end if;
  if not (m.can_open_calls or m.is_org_admin) then raise exception 'You are not set up to open service calls.'; end if;
  if p_issue_type is null then raise exception 'Pick what the problem is from the list.'; end if;
  if nullif(trim(p_po_number), '') is not null and exists (select 1 from work_orders x where x.customer_id = s.customer_id
       and x.store_po_number = trim(p_po_number) and x.status not in ('cancelled','invoiced')) then
    raise exception 'PO % is already on an open call.', trim(p_po_number);
  end if;
  w := _create_call(p_site, p_issue_type, p_details, p_equipment, p_priority, p_po_number, 'service',
                    p_contractor, null, p_id, m.id, 'store', p_nte);
  if w.mode = 'full' and p_nte is not null then
    raise exception 'This contractor works under approved amounts — the not-to-exceed is set by the approval letters.';
  end if;
  if nullif(trim(p_unit), '') is not null then
    perform _allow_internal(); update work_orders set unit = trim(p_unit) where id = w.id returning * into w; perform _end_internal();
  end if;
  return w;
end $$;

-- Contractor office: a call that came in by phone. The store is asked to confirm it.
create or replace function enter_phone_call(p_site uuid, p_issue_type uuid, p_details text, p_caller_name text,
  p_caller_phone text default null, p_po_number text default null, p_priority smallint default null,
  p_equipment uuid default null, p_id uuid default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; w work_orders;
begin
  if p_id is not null and exists (select 1 from work_orders where id = p_id) then
    return (select x from work_orders x where x.id = p_id and can_see_work_order(x.id));
  end if;
  if m.contractor_id is null or not (m.is_org_admin or m.can_dispatch) then raise exception 'Only the contractor office can enter calls.'; end if;
  select * into s from sites where id = p_site;
  if s.id is null or not exists (select 1 from customer_contractors where contractor_id = m.contractor_id and customer_id = s.customer_id) then
    raise exception 'That location is not one of your customers.';
  end if;
  if coalesce(length(trim(p_caller_name)), 0) < 2 then raise exception 'Enter the name of the person who called.'; end if;
  w := _create_call(p_site, p_issue_type, p_details, p_equipment, p_priority, p_po_number, 'service',
                    m.contractor_id, null, p_id, m.id, 'contractor', null, p_caller_name);
  perform _allow_internal();
  update work_orders set contact_phone = nullif(trim(p_caller_phone), '') where id = w.id returning * into w;
  perform _end_internal();
  return w;
end $$;

-- ---------- Office: accept / schedule, or decline ----------------------------
create or replace function accept_call(p_wo uuid, p_when text default 'now', p_start timestamptz default null,
  p_end timestamptz default null, p_note text default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders; m profiles := me(); s sites; msg text;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or not is_contractor_office(w.contractor_id) then raise exception 'Only the contractor office can accept calls.'; end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'This call is closed.'; end if;
  select * into s from sites where id = w.site_id;
  if p_when = 'scheduled' then
    if p_start is null then raise exception 'Pick when you will be there.'; end if;
    if p_end is not null and p_end <= p_start then raise exception 'The window must end after it starts.'; end if;
    msg := format('%s accepted call #%s (%s) — scheduled %s%s.', (select name from contractors where id = w.contractor_id),
      w.number, _po(w), _local(p_start, w.site_id, 'Dy Mon DD HH12:MI AM'),
      case when p_end is not null then '–' || _local(p_end, w.site_id, 'HH12:MI AM') else '' end);
  elsif p_when = 'now' then
    msg := format('%s accepted call #%s (%s) — a technician is coming now.', (select name from contractors where id = w.contractor_id), w.number, _po(w));
  else
    raise exception 'Choose now or a scheduled time.';
  end if;
  perform _allow_internal();
  update work_orders set accepted_at = coalesce(accepted_at, now()), accepted_by = coalesce(accepted_by, m.id),
         scheduled_start = case when p_when = 'scheduled' then p_start end,
         scheduled_end = case when p_when = 'scheduled' then p_end end,
         accept_note = nullif(trim(p_note), ''), declined_at = null, decline_reason = null
   where id = w.id returning * into w;
  perform _end_internal();
  update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Accepted'
   where work_order_id = w.id and flag = 'not_accepted' and resolved_at is null;
  perform _notify_customer(w.id, 'assigned', msg || coalesce(' Note: ' || nullif(trim(p_note), ''), ''));
  return w;
end $$;

create or replace function decline_call(p_wo uuid, p_reason text)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or not is_contractor_office(w.contractor_id) then raise exception 'Only the contractor office can decline calls.'; end if;
  if exists (select 1 from visits where work_order_id = w.id and status in ('en_route','on_site','done')) then
    raise exception 'A technician has already gone on this call.';
  end if;
  if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'Say why (e.g. "No one available until Monday").'; end if;
  perform _allow_internal();
  update work_orders set declined_at = now(), decline_reason = trim(p_reason), accepted_at = null, accepted_by = null
   where id = w.id returning * into w;
  perform _end_internal();
  perform _raise_flag(w.id, 'not_accepted', format('Declined by %s: %s', (select name from contractors where id = w.contractor_id), trim(p_reason)), false, true);
  perform _notify_customer(w.id, 'sla_missed', format('%s can''t take call #%s (%s): %s. Pick another contractor on the call, or phone them.',
    (select name from contractors where id = w.contractor_id), w.number, _po(w), trim(p_reason)));
  return w;
end $$;

-- Store: send a call nobody has gone on yet to a different contractor
create or replace function reroute_call(p_wo uuid, p_contractor uuid)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders; m profiles := me(); cc customer_contractors; s sites;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or not (is_customer_member(w.customer_id) and can_see_site(w.site_id) and (m.can_open_calls or m.is_org_admin)) then
    raise exception 'Not allowed.';
  end if;
  if exists (select 1 from visits where work_order_id = w.id and status <> 'cancelled') then
    raise exception 'A technician has already been sent. Cancel the call instead.';
  end if;
  cc := _cc(w.customer_id, p_contractor);
  if cc.contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  select * into s from sites where id = w.site_id;
  perform _allow_internal();
  update work_orders set contractor_id = p_contractor, mode = cc.mode,
         accepted_at = null, accepted_by = null, declined_at = null, decline_reason = null, scheduled_start = null, scheduled_end = null,
         accept_due_at = now() + make_interval(mins => case when priority = 1 then cc.accept_emergency_min else cc.accept_normal_min end)
   where id = w.id returning * into w;
  perform _end_internal();
  update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Sent to another contractor'
   where work_order_id = w.id and flag = 'not_accepted' and resolved_at is null;
  perform _notify_office(w.id, 'new_call', format('New %sPO call #%s (%s) at %s: %s. Please accept by %s.',
    case when w.priority = 1 then 'EMERGENCY ' else '' end, w.number, _po(w), s.name, w.issue_description,
    _local(w.accept_due_at, w.site_id, 'HH12:MI AM Dy')));
  return w;
end $$;

-- Any visit (dispatch assigning, or a tech taking it) means the contractor has accepted the call.
create or replace function _visit_accepts() returns trigger
language plpgsql security definer set search_path = public as $$
declare prev text := coalesce(current_setting('app.internal', true), 'off'); w work_orders;
begin
  select * into w from work_orders where id = new.work_order_id;
  if w.accepted_at is null then
    perform set_config('app.internal', 'on', true);
    update work_orders set accepted_at = now(), accepted_by = coalesce(auth.uid(), new.technician_id), declined_at = null
     where id = w.id;
    perform set_config('app.internal', prev, true);
    update guardrail_flags set resolved_at = now(), resolution_note = 'Accepted'
     where work_order_id = w.id and flag = 'not_accepted' and resolved_at is null;
  end if;
  return null;
end $$;
create trigger visits_accept after insert on visits for each row execute function _visit_accepts();

-- Every few minutes: Time Verify calls not accepted in time → the store is told (and the office again).
create or replace function accept_watch() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select w.*, s.name site_name, c.name contractor_name, c.phone contractor_phone
             from work_orders w join sites s on s.id = w.site_id join contractors c on c.id = w.contractor_id
            where w.mode = 'verify' and w.status = 'created' and w.accepted_at is null and w.declined_at is null
              and w.accept_due_at < now() loop
    perform _raise_flag(r.id, 'not_accepted', format('%s has not accepted the call (due %s).', r.contractor_name,
      _local(r.accept_due_at, r.site_id, 'HH12:MI AM')), false, true);
    perform _notify_customer(r.id, 'sla_missed', format('%s has NOT accepted call #%s (%s) at %s yet.%s Call them, or send it to another contractor.',
      r.contractor_name, r.number, coalesce(r.store_po_number, 'PO' || r.number), r.site_name,
      case when r.contractor_phone is not null then ' Phone: ' || r.contractor_phone || '.' else '' end), 'notacc:' || r.id);
    perform _notify_office(r.id, 'sla_missed', format('OVERDUE: call #%s at %s is waiting for you to accept it. The store has been told.',
      r.number, r.site_name), 'notacc:' || r.id);
    n := n + 1;
  end loop;
  -- Contractor-entered calls the store still hasn't confirmed after a day: remind the store once.
  for r in select w.* from work_orders w where w.mode = 'verify' and w.source = 'contractor' and w.store_confirmed_at is null
              and not w.store_disputed and w.created_at < now() - interval '1 day' and w.status <> 'cancelled' loop
    perform _notify_customer(r.id, 'new_call', format('Reminder: please confirm call #%s (%s) that %s entered — did your store request it?',
      r.number, coalesce(r.store_po_number, 'PO' || r.number), (select name from contractors where id = r.contractor_id)), 'confirm_remind:' || r.id);
  end loop;
  return n;
end $$;

-- ---------- Store: confirm a contractor-entered call --------------------------
create or replace function store_confirm_call(p_wo uuid, p_confirm boolean, p_po_number text default null, p_note text default null)
returns work_orders language plpgsql security definer set search_path = public as $$
declare w work_orders; m profiles := me();
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or not (is_customer_member(w.customer_id) and can_see_site(w.site_id)
     and (m.can_open_calls or m.can_approve or m.is_org_admin)) then raise exception 'Not allowed.'; end if;
  if w.source <> 'contractor' then raise exception 'Your store opened this call — nothing to confirm.'; end if;
  if p_confirm then
    perform _allow_internal(true);
    update work_orders set store_confirmed_at = now(), store_confirmed_by = m.id, store_disputed = false,
           store_po_number = coalesce(nullif(trim(p_po_number), ''), store_po_number)
     where id = w.id returning * into w;
    perform _end_internal();
    update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Confirmed by ' || m.full_name
     where work_order_id = w.id and flag = 'call_unconfirmed' and resolved_at is null;
    perform _notify_office(w.id, 'new_call', format('%s confirmed call #%s (%s).', m.full_name, w.number, _po(w)));
  else
    if coalesce(length(trim(p_note)), 0) < 5 then raise exception 'Say what is wrong with this call.'; end if;
    perform _allow_internal(true);
    update work_orders set store_disputed = true, store_confirmed_at = null, store_confirmed_by = null where id = w.id returning * into w;
    perform _end_internal();
    perform _raise_flag(w.id, 'call_unconfirmed', format('%s (store) says: %s', m.full_name, trim(p_note)), false, true);
    perform _notify_office(w.id, 'guardrail_flag', format('%s questioned call #%s: %s', m.full_name, w.number, trim(p_note)));
  end if;
  return w;
end $$;

-- ---------- Technician: "I'm going" (takes the call; first one wins) --------
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
    raise exception 'Already taken — % is going.', (select full_name from profiles where id = v.technician_id);
  end if;
  if w.status not in ('created','assigned','return_needed','waiting_parts') then
    raise exception 'This call is % — nothing to go to.', replace(w.status::text, '_', ' ');
  end if;
  if w.declined_at is not null then raise exception 'Your office declined this call.'; end if;

  select coalesce(max(visit_no), 0) + 1 into n from visits where work_order_id = w.id;
  insert into visits (work_order_id, visit_no, technician_id, checkin_required, status, assigned_at, received_at, started_at)
  values (w.id, n, m.id, w.require_checkin, 'en_route', t, t, t) returning * into v;
  if w.require_checkin then
    insert into visit_codes (visit_id, code) values (v.id, lpad((floor(random() * 10000))::int::text, 4, '0'));
  end if;
  perform _set_status(w.id, 'en_route');
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, event, recorded_at)
    values (m.id, w.id, v.id, p_lat, p_lon, 'en_route', t);
  end if;
  perform _notify_customer(w.id, 'eta_update', format('%s is on the way for call #%s (%s)%s.', m.full_name, w.number, _po(w),
    case when n > 1 then ', return visit' else '' end));
  perform _notify_office(w.id, 'assigned', format('%s took call #%s and is on the way.', m.full_name, w.number), 'claim:' || v.id);
  return v;
end $$;

-- ---------- Technician: parts run (leave the site → at the supplier → back) --
-- p_step: leave | at_supplier | back. Each step can be sent again safely (phone resync).
create or replace function tech_parts_run(p_visit uuid, p_step text, p_id uuid default null, p_supplier text default null,
  p_at timestamptz default null, p_lat double precision default null, p_lon double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders; s sites; r parts_runs; d double precision;
begin
  select * into w from work_orders where id = v.work_order_id;
  select * into s from sites where id = w.site_id;
  select * into r from parts_runs where id = coalesce(p_id, (select id from parts_runs where visit_id = v.id and returned_at is null
                                                              order by left_at desc limit 1)) and visit_id = v.id;
  if p_step = 'leave' then
    if r.id is not null then return to_jsonb(r); end if;
    perform _on_site(v);
    if exists (select 1 from parts_runs where visit_id = v.id and returned_at is null) then
      raise exception 'You are already on a parts run.';
    end if;
    insert into parts_runs (id, visit_id, work_order_id, technician_id, supplier, left_at, left_lat, left_lon)
    values (coalesce(p_id, gen_random_uuid()), v.id, w.id, v.technician_id, nullif(trim(p_supplier), ''),
            greatest(t, v.arrived_at, coalesce((select max(returned_at) from parts_runs where visit_id = v.id), v.arrived_at)), p_lat, p_lon)
    returning * into r;
    perform _notify_customer(w.id, 'departure', format('Call #%s: the technician left to get parts%s at %s. Time away is tracked by GPS.',
      w.number, coalesce(' (' || r.supplier || ')', ''), _local(r.left_at, w.site_id, 'HH12:MI AM')), 'prun:' || r.id);
  elsif p_step = 'at_supplier' then
    if r.id is null then raise exception 'Start the parts run first.'; end if;
    if r.at_supplier_at is null and r.returned_at is null then
      update parts_runs set at_supplier_at = greatest(t, left_at), supplier = coalesce(nullif(trim(p_supplier), ''), supplier),
             supplier_lat = p_lat, supplier_lon = p_lon where id = r.id returning * into r;
    end if;
  elsif p_step = 'back' then
    if r.id is null then raise exception 'No parts run to end.'; end if;
    if r.returned_at is null then
      update parts_runs set returned_at = greatest(t, left_at, coalesce(at_supplier_at, left_at)), return_lat = p_lat, return_lon = p_lon
       where id = r.id returning * into r;
      if p_lat is not null and s.lat is not null then
        d := distance_ft(p_lat, p_lon, s.lat, s.lon);
        if d > s.geofence_radius_ft * 2 then
          perform _raise_flag(w.id, 'gps_mismatch', format('"Back on site" after the parts run was recorded %s ft from the site.', round(d::numeric)), false, true);
        end if;
      end if;
      perform _notify_customer(w.id, 'arrival', format('Call #%s: the technician is back on site (away %s).', w.number,
        _hm(ceil(extract(epoch from (r.returned_at - r.left_at)) / 60)::int)), 'prun_back:' || r.id);
    end if;
  else
    raise exception 'Unknown step.';
  end if;
  return to_jsonb(r);
end $$;

-- ---------- Technician: "Leaving" (Time Verify) ------------------------------
-- p_outcome: completed (done) | return_needed (coming back) | parts_needed (waiting for parts)
create or replace function tech_leave(p_visit uuid, p_outcome visit_outcome, p_note text default null,
  p_at timestamptz default null, p_lat double precision default null, p_lon double precision default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders; s sites; note text; mins int;
begin
  if v.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  perform _on_site(v);
  select * into w from work_orders where id = v.work_order_id;
  select * into s from sites where id = w.site_id;
  if w.mode <> 'verify' then raise exception 'Use Finish for this job.'; end if;
  if p_outcome = 'quote_needed' then raise exception 'Not used on Time Verify calls.'; end if;
  if exists (select 1 from parts_runs where visit_id = v.id and returned_at is null) then
    return jsonb_build_object('ok', false, 'missing', jsonb_build_array(jsonb_build_object('item', 'parts_run',
      'message', 'You are still on a parts run. Tap "Back on site" first.')));
  end if;
  if v.checkin_required and v.checkin_at is null then
    return jsonb_build_object('ok', false, 'missing', jsonb_build_array(jsonb_build_object('item', 'checkin',
      'message', 'Check in with the store first (their code), or use "No code available".')));
  end if;
  if w.require_checkout and v.checkout_at is null then
    return jsonb_build_object('ok', false, 'missing', jsonb_build_array(jsonb_build_object('item', 'checkout',
      'message', 'Check out with the store person before leaving.')));
  end if;
  t := greatest(t, v.arrived_at, coalesce((select max(returned_at) from parts_runs where visit_id = v.id), v.arrived_at));
  note := nullif(trim(p_note), '');
  update visits set status = 'done', outcome = p_outcome, outcome_note = note, completed_at = t, departed_at = coalesce(departed_at, t)
   where id = v.id returning * into v;
  if p_lat is not null then
    insert into gps_logs (technician_id, work_order_id, visit_id, lat, lon, event, recorded_at)
    values (v.technician_id, w.id, v.id, p_lat, p_lon, 'completed', t);
  end if;
  mins := coalesce((select (x->>'onsite_min')::int from jsonb_array_elements(_verified(w.id)->'visits') x where (x->>'visit_id')::uuid = v.id), 0);

  perform _allow_internal();
  if p_outcome = 'completed' then
    update work_orders set status = 'completed', completed_at = t,
           invoice_due_at = t + make_interval(days => _billing_days(w.id)),
           work_summary = case when note is null then work_summary else coalesce(work_summary || E'\n', '') || note end
     where id = w.id returning * into w;
  else
    update work_orders set status = case when p_outcome = 'parts_needed' then 'waiting_parts'::wo_status else 'return_needed'::wo_status end,
           work_summary = coalesce(work_summary || E'\n', '') ||
             case when p_outcome = 'parts_needed' then 'Waiting for parts' else 'Coming back' end || coalesce(': ' || note, '')
     where id = w.id returning * into w;
  end if;
  perform _end_internal();

  if p_outcome = 'completed' then
    perform _notify_customer(w.id, 'completed', format('Call #%s (%s) at %s is done — %s verified on site. The contractor''s invoice is due by %s.',
      w.number, _po(w), s.name, _hm(mins), _local(w.invoice_due_at, w.site_id, 'Mon DD')));
    perform _notify_office(w.id, 'completed', format('Call #%s (%s) done — %s on site. Enter the invoice by %s (the store requires it here).',
      w.number, _po(w), _hm(mins), _local(w.invoice_due_at, w.site_id, 'Mon DD')));
  else
    perform _notify_customer(w.id, 'parts_waiting', format('Call #%s: the technician left after %s on site — %s%s.', w.number, _hm(mins),
      case when p_outcome = 'parts_needed' then 'waiting for parts' else 'coming back' end, coalesce(': ' || note, '')));
    perform _notify_office(w.id, 'parts_waiting', format('Call #%s: %s%s.', w.number,
      case when p_outcome = 'parts_needed' then 'waiting for parts' else 'needs a return visit' end, coalesce(': ' || note, '')));
  end if;
  return jsonb_build_object('ok', true, 'status', w.status, 'onsite_min', mins);
end $$;

-- ---------- Store: "The tech is here but didn't check in" --------------------
create or replace function store_tech_here(p_wo uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; v visits; s sites; tname text;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null or not (is_customer_member(w.customer_id) and can_see_site(w.site_id)) then raise exception 'Not allowed.'; end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'This call is closed.'; end if;
  select * into s from sites where id = w.site_id;
  select * into v from visits where work_order_id = w.id and status in ('assigned','en_route','on_site') limit 1 for update;
  if v.status = 'on_site' then return jsonb_build_object('ok', true, 'already', true); end if;

  perform _allow_internal();
  update work_orders set store_seen_at = coalesce(store_seen_at, now()), store_seen_by = coalesce(store_seen_by, m.id) where id = w.id;
  perform _end_internal();
  if v.id is null then
    perform _raise_flag(w.id, 'arrival_by_store', format('%s (store) says a technician arrived at %s, but no one has taken the call in the app.',
      m.full_name, _local(now(), w.site_id, 'HH12:MI AM')), false, true);
    perform _notify_office(w.id, 'arrival', format('Call #%s: %s at %s says your technician is there, but no one took the call in the app. Have them tap "I''m going" and "I''m here".',
      w.number, m.full_name, s.name), 'store_seen:' || w.id);
    return jsonb_build_object('ok', true, 'no_visit', true);
  end if;

  update visits set status = 'on_site', started_at = coalesce(started_at, now()), received_at = coalesce(received_at, now()),
         arrived_at = now(), arrival_source = 'store' where id = v.id returning * into v;
  perform _allow_internal();
  update work_orders set status = case when status = 'awaiting_approval' then status else 'on_site' end,
         first_arrived_at = coalesce(first_arrived_at, v.arrived_at),
         response_met = case when response_due_at is not null and first_arrived_at is null then v.arrived_at <= response_due_at else response_met end
   where id = w.id;
  perform _end_internal();
  tname := (select full_name from profiles where id = v.technician_id);
  perform _raise_flag(w.id, 'arrival_by_store', format('Arrival recorded by %s (store) at %s — %s had not tapped "I''m here".%s',
    m.full_name, _local(v.arrived_at, w.site_id, 'HH12:MI AM'), tname, coalesce(' ' || nullif(trim(p_note), ''), '')), false, true);
  perform _notify(v.technician_id, w.id, 'arrival', format('The store says you are at %s for job #%s. Open the job and check in.', s.name, w.number),
    'store_here:' || v.id);
  perform _notify_office(w.id, 'arrival', format('Call #%s: the store recorded %s''s arrival — they had not tapped "I''m here".', w.number, tname),
    'store_here:' || v.id);
  return jsonb_build_object('ok', true, 'visit_id', v.id, 'technician', tname);
end $$;


-- ---------- Verified hours (what the GPS and the store's code prove) -------------------------
-- Per visit: on site = arrival → leaving, minus parts runs; travel = "I'm going" → arrival;
-- parts runs = left the site → back. Travel counts only if the store pays travel (yes / after hours only).
-- "Expected billable" applies the contractor's minimum per visit and billing increment.
create or replace function _verified(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; cc customer_contractors; r record; e timestamptz; arr jsonb := '[]';
  onsite int; travel int; tcount int; away int; away_ver int; bill int;
  t_on int := 0; t_tr int := 0; t_trc int := 0; t_pr int := 0; t_prv int := 0; t_bill int := 0; inc int;
begin
  select * into w from work_orders where id = p_wo;
  cc := _cc(w.customer_id, w.contractor_id);
  inc := coalesce(cc.increment_min, 15);
  for r in select v.*, p.full_name tech from visits v join profiles p on p.id = v.technician_id
            where v.work_order_id = p_wo and v.status <> 'cancelled' and v.arrived_at is not null order by v.visit_no loop
    e := coalesce(r.completed_at, r.departed_at, now());
    select coalesce(sum(ceil(extract(epoch from (coalesce(pr.returned_at, e) - pr.left_at)) / 60)), 0),
           coalesce(sum(ceil(extract(epoch from (coalesce(pr.returned_at, e) - pr.left_at)) / 60)) filter (where pr.at_supplier_at is not null and pr.returned_at is not null), 0)
      into away, away_ver from parts_runs pr where pr.visit_id = r.id;
    onsite := greatest(0, ceil(extract(epoch from (e - r.arrived_at)) / 60)::int - away);
    travel := case when r.started_at is not null then greatest(0, ceil(extract(epoch from (r.arrived_at - r.started_at)) / 60))::int else 0 end;
    tcount := case coalesce(cc.pays_travel, 'yes') when 'yes' then travel when 'after_hours' then case when w.after_hours then travel else 0 end else 0 end;
    bill := greatest(round(coalesce(cc.min_hours, 1) * 60)::int, (ceil((onsite + away + tcount)::numeric / inc) * inc)::int);
    arr := arr || jsonb_build_object('visit_id', r.id, 'visit_no', r.visit_no, 'tech', r.tech, 'started_at', r.started_at,
      'arrived_at', r.arrived_at, 'left_at', r.completed_at, 'arrival_by_store', r.arrival_source = 'store',
      'checkin_verified', r.checkin_verified, 'outcome', r.outcome, 'open', r.completed_at is null,
      'onsite_min', onsite, 'travel_min', travel, 'travel_counted_min', tcount, 'parts_run_min', away,
      'parts_run_unverified_min', away - away_ver, 'billable_min', bill);
    t_on := t_on + onsite; t_tr := t_tr + travel; t_trc := t_trc + tcount; t_pr := t_pr + away; t_prv := t_prv + (away - away_ver); t_bill := t_bill + bill;
  end loop;
  return jsonb_build_object('visits', arr, 'pays_travel', coalesce(cc.pays_travel, 'yes'), 'min_hours', cc.min_hours, 'increment_min', inc,
    'onsite_h', round(t_on / 60.0, 2), 'travel_h', round(t_tr / 60.0, 2), 'travel_counted_h', round(t_trc / 60.0, 2),
    'parts_run_h', round(t_pr / 60.0, 2), 'parts_run_unverified_h', round(t_prv / 60.0, 2),
    'verified_h', round((t_on + t_trc + t_pr) / 60.0, 2), 'billable_h', round(t_bill / 60.0, 2), 'nte', w.nte);
end $$;

create or replace function verified_hours(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_see_work_order(p_wo) then raise exception 'Not allowed.'; end if;
  return _verified(p_wo);
end $$;

-- Billed vs verified for the invoice on a call
create or replace function _invoice_check(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb := _verified(p_wo); i call_invoices; explained numeric; unexpl numeric; nte numeric;
begin
  select * into i from call_invoices where work_order_id = p_wo;
  if i.work_order_id is null then return v || jsonb_build_object('invoice', null); end if;
  nte := (v->>'nte')::numeric;
  explained := (v->>'billable_h')::numeric + i.other_hours;
  unexpl := greatest(0, round(i.hours_billed - explained, 2));
  return v || jsonb_build_object('invoice', jsonb_build_object('number', i.invoice_number, 'total', i.total, 'status', i.status),
    'billed_h', i.hours_billed, 'other_h', i.other_hours, 'other_reason', i.other_reason,
    'explained_h', explained, 'unexplained_h', unexpl,
    'under_h', greatest(0, round((v->>'billable_h')::numeric - i.hours_billed, 2)),
    'over_nte', nte is not null and i.total > nte, 'over_nte_by', case when nte is not null and i.total > nte then i.total - nte end,
    'all_verified', unexpl = 0);
end $$;

create or replace function invoice_check(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not can_see_work_order(p_wo) then raise exception 'Not allowed.'; end if;
  return _invoice_check(p_wo);
end $$;

-- Contractor enters the invoice (required). The store may type it in from a paper/emailed invoice if the contractor hasn't.
create or replace function submit_invoice(p_wo uuid, p_invoice_number text, p_total numeric, p_hours_billed numeric,
  p_other_hours numeric default 0, p_other_reason text default null, p_other_photo_path text default null, p_po_number text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; side text; old call_invoices; chk jsonb; s sites; msg text;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null then raise exception 'Unknown call.'; end if;
  if is_contractor_office(w.contractor_id) then side := 'contractor';
  elsif is_customer_member(w.customer_id) and can_see_site(w.site_id) and (m.can_see_billing or m.can_approve or m.is_org_admin) then side := 'store';
  else raise exception 'Not allowed.'; end if;
  if w.mode <> 'verify' then raise exception 'Invoices for this call go through billing.'; end if;
  if w.status not in ('completed','invoiced') then raise exception 'The call must be finished before it is invoiced.'; end if;
  select * into old from call_invoices where work_order_id = w.id for update;
  if old.status = 'approved' then raise exception 'The store already approved this invoice.'; end if;
  if side = 'store' and old.entered_side = 'contractor' then raise exception 'The contractor already entered this invoice.'; end if;
  if coalesce(trim(p_invoice_number), '') = '' then raise exception 'Enter the invoice number.'; end if;
  if p_total is null or p_total < 0 then raise exception 'Enter the invoice total.'; end if;
  if p_hours_billed is null or p_hours_billed < 0 or p_hours_billed > 200 then raise exception 'Enter the hours billed.'; end if;
  if coalesce(p_other_hours, 0) < 0 then raise exception 'Other hours cannot be negative.'; end if;
  if coalesce(p_other_hours, 0) > 0 and coalesce(length(trim(p_other_reason)), 0) < 5 then
    raise exception 'Say what the other hours were for (shop work, picking up parts, …).';
  end if;

  insert into call_invoices (work_order_id, invoice_number, po_number, total, hours_billed, other_hours, other_reason, other_photo_path,
                             entered_side, entered_by, entered_at, status)
  values (w.id, trim(p_invoice_number), coalesce(nullif(trim(p_po_number), ''), _po(w)), p_total, p_hours_billed, coalesce(p_other_hours, 0),
          nullif(trim(p_other_reason), ''), nullif(trim(p_other_photo_path), ''), side, m.id, now(), 'submitted')
  on conflict (work_order_id) do update set invoice_number = excluded.invoice_number, po_number = excluded.po_number,
    total = excluded.total, hours_billed = excluded.hours_billed, other_hours = excluded.other_hours, other_reason = excluded.other_reason,
    other_photo_path = excluded.other_photo_path, entered_side = excluded.entered_side, entered_by = excluded.entered_by,
    entered_at = now(), status = 'submitted', reviewed_by = null, reviewed_at = null, review_note = null;
  chk := _invoice_check(w.id);
  update call_invoices set check_result = chk where work_order_id = w.id;

  if (chk->>'unexplained_h')::numeric > 0 then
    perform _raise_flag(w.id, 'invoice_unexplained', format('Invoice %s bills %s h; %s h verified/expected%s — %s h not explained.',
      trim(p_invoice_number), chk->>'billed_h', chk->>'billable_h',
      case when coalesce(p_other_hours, 0) > 0 then format(' + %s h %s', p_other_hours, trim(p_other_reason)) else '' end,
      chk->>'unexplained_h'), false, true);
  else
    update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Invoice hours match'
     where work_order_id = w.id and flag = 'invoice_unexplained' and resolved_at is null;
  end if;
  if (chk->>'over_nte')::boolean then
    perform _raise_flag(w.id, 'invoice_over_nte', format('Invoice total $%s is over the $%s not-to-exceed by $%s.',
      p_total, w.nte, chk->>'over_nte_by'), false, true);
  else
    update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Within the not-to-exceed'
     where work_order_id = w.id and flag = 'invoice_over_nte' and resolved_at is null;
  end if;
  update guardrail_flags set resolved_at = now(), resolution_note = 'Invoice entered'
   where work_order_id = w.id and flag = 'billing_late' and resolved_at is null;

  perform _allow_internal(true);
  update work_orders set status = 'invoiced', invoiced_at = coalesce(invoiced_at, now()), qbo_invoice_id = trim(p_invoice_number)
   where id = w.id returning * into w;
  perform _end_internal();

  msg := format('Invoice %s for call #%s (%s): $%s, %s h billed — %s.', trim(p_invoice_number), w.number, _po(w), p_total, p_hours_billed,
    case when (chk->>'unexplained_h')::numeric > 0 then format('%s h verified/expected, %s h NOT explained', chk->>'billable_h', chk->>'unexplained_h')
         else 'hours match what was verified' end)
    || case when (chk->>'over_nte')::boolean then format(' Over your $%s limit by $%s.', w.nte, chk->>'over_nte_by') else '' end;
  if side = 'contractor' then
    perform _notify_customer(w.id, 'billing_due', msg);
  else
    perform _notify_office(w.id, 'billing_due', format('%s (store) entered your invoice for call #%s from their copy: %s Please check it.',
      m.full_name, w.number, msg));
  end if;
  return chk;
end $$;

create or replace function store_review_invoice(p_wo uuid, p_ok boolean, p_note text default null)
returns call_invoices language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; i call_invoices;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not (is_customer_member(w.customer_id) and can_see_site(w.site_id)
     and (m.can_see_billing or m.can_approve or m.is_org_admin)) then raise exception 'Not allowed.'; end if;
  select * into i from call_invoices where work_order_id = p_wo for update;
  if i.work_order_id is null then raise exception 'No invoice yet.'; end if;
  if not p_ok and coalesce(length(trim(p_note)), 0) < 5 then raise exception 'Say what is wrong with the invoice.'; end if;
  update call_invoices set status = case when p_ok then 'approved' else 'disputed' end, reviewed_by = m.id, reviewed_at = now(),
         review_note = nullif(trim(p_note), '') where work_order_id = p_wo returning * into i;
  perform _notify_office(p_wo, 'billing_due', format('%s %s invoice %s for call #%s%s', m.full_name,
    case when p_ok then 'approved' else 'questioned' end, i.invoice_number, w.number, coalesce(': ' || i.review_note, '.')));
  return i;
end $$;

-- ---------- Relationship settings --------------------------------------------
-- Store admin: Time Verify or full, who pays travel, how fast calls must be accepted.
create or replace function set_contractor_terms(p_contractor uuid, p_mode text default null, p_pays_travel text default null,
  p_accept_emergency_min int default null, p_accept_normal_min int default null)
returns customer_contractors language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors;
begin
  if m.customer_id is null or not is_customer_admin(m.customer_id) then raise exception 'Only your company''s admin can change this.'; end if;
  update customer_contractors set mode = coalesce(p_mode, mode), pays_travel = coalesce(p_pays_travel, pays_travel),
         accept_emergency_min = coalesce(p_accept_emergency_min, accept_emergency_min),
         accept_normal_min = coalesce(p_accept_normal_min, accept_normal_min)
   where customer_id = m.customer_id and contractor_id = p_contractor returning * into cc;
  if cc.contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  return cc;
end $$;

-- Contractor office: their minimum charge and billing increment for this store
create or replace function set_my_terms(p_customer uuid, p_min_hours numeric, p_increment_min int)
returns customer_contractors language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors;
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) then raise exception 'Only your owner or billing can change this.'; end if;
  update customer_contractors set min_hours = p_min_hours, increment_min = p_increment_min
   where customer_id = p_customer and contractor_id = m.contractor_id returning * into cc;
  if cc.contractor_id is null then raise exception 'Not one of your customers.'; end if;
  return cc;
end $$;

-- Store admin: which contractor gets which trade (p_site null = all locations; p_contractor null = primary)
create or replace function set_trade_contractor(p_site uuid, p_trade smallint, p_contractor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cust uuid;
begin
  if m.customer_id is null or not is_customer_admin(m.customer_id) then raise exception 'Only your company''s admin can change this.'; end if;
  cust := m.customer_id;
  if p_site is not null and not exists (select 1 from sites where id = p_site and customer_id = cust) then raise exception 'Not your location.'; end if;
  if (_cc(cust, p_contractor)).contractor_id is null and p_contractor is not null then raise exception 'That contractor does not serve you.'; end if;
  if p_site is null then
    update trade_contractors set contractor_id = p_contractor, updated_at = now() where customer_id = cust and site_id is null and trade_id = p_trade;
  else
    update trade_contractors set contractor_id = p_contractor, updated_at = now() where site_id = p_site and trade_id = p_trade;
  end if;
  if not found then
    insert into trade_contractors (customer_id, site_id, trade_id, contractor_id) values (cust, p_site, p_trade, p_contractor);
  end if;
end $$;

create or replace function set_report_pin(p_site uuid, p_pin text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sites s where s.id = p_site and is_customer_admin(s.customer_id)) then
    raise exception 'Only your company''s admin can set the PIN.';
  end if;
  if trim(p_pin) !~ '^[0-9]{4,6}$' then raise exception 'The PIN must be 4 to 6 digits.'; end if;
  insert into site_report_pins (site_id, pin_hash) values (p_site, extensions.crypt(trim(p_pin), extensions.gen_salt('bf')))
  on conflict (site_id) do update set pin_hash = excluded.pin_hash, updated_at = now();
end $$;

create or replace function site_has_report_pin(p_site uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select can_see_site(p_site) and exists (select 1 from site_report_pins where site_id = p_site)
$$;

-- ---------- QR sticker on a unit (no login; the store PIN is the key) --------
create or replace function qr_info(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e equipment; s sites; et equipment_types;
begin
  select * into e from equipment where qr_token = p_token;
  if e.id is null then return jsonb_build_object('ok', false); end if;
  select * into s from sites where id = e.site_id;
  select * into et from equipment_types where id = e.equipment_type_id;
  return jsonb_build_object('ok', true, 'store', (select name from customers where id = s.customer_id), 'site', s.name,
    'unit', concat_ws(' — ', et.name, e.location_description), 'has_pin', exists (select 1 from site_report_pins where site_id = s.id),
    'issues', (select coalesce(jsonb_agg(jsonb_build_object('id', it.id, 'name', it.name, 'priority', it.priority) order by it.priority, it.name), '[]')
               from issue_types it where it.active and (et.trade_id is null or it.trade_id = et.trade_id)
                 and (it.equipment_type_code is null or it.equipment_type_code = et.code)),
    'open_calls', (select coalesce(jsonb_agg(jsonb_build_object('number', w.number, 'status', w.status, 'problem', w.issue_description,
                     'opened', _local(w.created_at, w.site_id, 'Mon DD HH12:MI AM')) order by w.created_at desc), '[]')
                   from work_orders w where w.equipment_id = e.id and w.status not in ('completed','invoiced','cancelled')));
end $$;

create or replace function qr_report(p_token uuid, p_pin text, p_issue_type uuid, p_details text, p_name text, p_emergency boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e equipment; pin site_report_pins; w work_orders; tries int;
begin
  select * into e from equipment where qr_token = p_token;
  if e.id is null then raise exception 'This sticker is not recognized.'; end if;
  select * into pin from site_report_pins where site_id = e.site_id;
  if pin.site_id is null then raise exception 'This store has not set a reporting PIN yet. Ask your manager.'; end if;
  select count(*) into tries from qr_attempts where token = p_token and at > now() - interval '15 minutes';
  if tries >= 5 then raise exception 'Too many wrong PINs. Wait 15 minutes or ask your manager.'; end if;
  if pin.pin_hash is distinct from extensions.crypt(coalesce(trim(p_pin), ''), pin.pin_hash) then
    insert into qr_attempts (token) values (p_token);    -- kept: we return instead of raising, so the try is counted
    return jsonb_build_object('ok', false, 'error', format('Wrong store PIN (%s of 5 tries).', tries + 1));
  end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter your name.'; end if;
  if p_issue_type is null and coalesce(length(trim(p_details)), 0) < 5 then raise exception 'Pick the problem or describe it.'; end if;
  if exists (select 1 from work_orders where equipment_id = e.id and status not in ('completed','invoiced','cancelled')
               and created_at > now() - interval '2 hours') then
    raise exception 'This unit was already reported in the last 2 hours — a call is open.';
  end if;
  w := _create_call(e.site_id, p_issue_type, p_details, e.id, case when p_emergency then 1::smallint end, null, 'service',
                    null, null, null, null, 'qr', null, trim(p_name));
  return jsonb_build_object('ok', true, 'number', w.number, 'po', _po(w), 'contractor', (select name from contractors where id = w.contractor_id));
end $$;

-- ---------- Sign-in links (no passwords to remember) -------------------------
-- A login is created behind the link; opening the link signs that phone in and keeps it signed in.
create or replace function _make_login(p_email text, p_password text, p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare uid uuid := gen_random_uuid();
begin
  if exists (select 1 from auth.users where lower(email) = lower(p_email)) then
    raise exception 'That email already has a login. Ask for a new sign-in link instead.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    execute $q$insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, confirmation_token,
        recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token,
        reauthentication_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      values ('00000000-0000-0000-0000-000000000000', $1, 'authenticated', 'authenticated', $2, extensions.crypt($3, extensions.gen_salt('bf')),
        now(), '', '', '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', $4), now(), now())$q$
      using uid, lower(p_email), p_password, p_name;
    execute $q$insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
      values (gen_random_uuid(), $1, $1::text, 'email', jsonb_build_object('sub', $1::text, 'email', $2, 'email_verified', true), now(), now(), now())$q$
      using uid, lower(p_email);
  else
    insert into auth.users (id, email) values (uid, lower(p_email));
  end if;
  return uid;
end $$;

create or replace function _set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    execute 'update auth.users set encrypted_password = extensions.crypt($2, extensions.gen_salt(''bf'')), updated_at = now() where id = $1'
      using p_user, p_password;
  end if;
end $$;

-- Store admin: invite a contractor to Time Verify (by email or phone). Returns the link token to send.
create or replace function invite_contractor(p_company text, p_contact_name text, p_email text default null, p_phone text default null,
  p_trade_ids smallint[] default '{}', p_site_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cid uuid; tok uuid; tr smallint; st uuid;
begin
  if m.customer_id is null or not is_customer_admin(m.customer_id) then raise exception 'Only your company''s admin can invite contractors.'; end if;
  if coalesce(length(trim(p_company)), 0) < 2 or coalesce(length(trim(p_contact_name)), 0) < 2 then
    raise exception 'Enter the company and the person''s name.';
  end if;
  if nullif(trim(p_email), '') is null and nullif(trim(p_phone), '') is null then raise exception 'Enter an email or a mobile number.'; end if;
  if p_site_ids is not null and exists (select 1 from unnest(p_site_ids) x where not exists (
       select 1 from sites s where s.id = x and s.customer_id = m.customer_id)) then raise exception 'Not your location.'; end if;
  insert into contractors (name, phone, email) values (trim(p_company), nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''))
  returning id into cid;
  insert into customer_contractors (contractor_id, customer_id, is_primary, mode)
  values (cid, m.customer_id, not exists (select 1 from customer_contractors where customer_id = m.customer_id), 'verify');
  foreach tr in array coalesce(p_trade_ids, '{}') loop
    if coalesce(cardinality(p_site_ids), 0) = 0 then
      perform set_trade_contractor(null, tr, cid);
    else
      foreach st in array p_site_ids loop perform set_trade_contractor(st, tr, cid); end loop;
    end if;
  end loop;
  insert into join_links (kind, contractor_id, customer_id, full_name, phone, email, created_by,
                          perms)
  values ('contractor_owner', cid, m.customer_id, trim(p_contact_name), nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''), m.id,
          '{"is_org_admin":true,"can_dispatch":true,"can_bill":true,"is_technician":true}')
  returning token into tok;
  return jsonb_build_object('token', tok, 'contractor_id', cid);
end $$;

-- Contractor owner: add a technician (or office person) by phone/email. Returns the link token to send.
create or replace function add_team_member(p_name text, p_phone text default null, p_email text default null,
  p_technician boolean default true, p_office boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare m profiles := me(); tok uuid;
begin
  if m.contractor_id is null or not m.is_org_admin then raise exception 'Only the owner can add people.'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter their name.'; end if;
  if nullif(trim(p_email), '') is null and nullif(trim(p_phone), '') is null then raise exception 'Enter a mobile number or an email.'; end if;
  if not (p_technician or p_office) then raise exception 'Pick technician and/or office.'; end if;
  insert into join_links (kind, contractor_id, full_name, phone, email, created_by, perms)
  values ('contractor_member', m.contractor_id, trim(p_name), nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''), m.id,
          jsonb_build_object('is_technician', p_technician, 'can_dispatch', p_office))
  returning token into tok;
  return tok;
end $$;

-- A fresh sign-in link for someone already set up (new phone, signed out).
create or replace function new_signin_link(p_profile uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); p profiles; tok uuid;
begin
  select * into p from profiles where id = p_profile;
  if p.id is null or not (p.id = m.id
     or (p.contractor_id is not null and m.contractor_id = p.contractor_id and m.is_org_admin)
     or (p.customer_id is not null and is_customer_admin(p.customer_id))) then raise exception 'Not allowed.'; end if;
  update join_links set expires_at = least(expires_at, now()) where profile_id = p.id and used_at is null;
  insert into join_links (kind, profile_id, contractor_id, customer_id, full_name, phone, email, created_by)
  values ('relink', p.id, p.contractor_id, p.customer_id, p.full_name, p.phone, p.email, m.id) returning token into tok;
  return tok;
end $$;

create or replace function join_info(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('ok', true, 'kind', l.kind, 'name', l.full_name,
      'company', coalesce((select name from contractors where id = l.contractor_id), (select name from customers where id = l.customer_id)),
      'invited_by', (select name from customers where id = l.customer_id and l.kind = 'contractor_owner'),
      'used', l.used_at is not null, 'expired', l.expires_at < now())
    from join_links l where l.token = p_token), jsonb_build_object('ok', false))
$$;

-- Opening the link: makes (or re-keys) the login and returns it once so the phone can sign in.
create or replace function join_redeem(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l join_links; pw text := encode(extensions.gen_random_bytes(24), 'base64'); em text; uid uuid; p profiles;
begin
  select * into l from join_links where token = p_token for update;
  if l.token is null then raise exception 'This link is not valid.'; end if;
  if l.used_at is not null then raise exception 'This link was already used. Ask for a new one.'; end if;
  if l.expires_at < now() then raise exception 'This link has expired. Ask for a new one.'; end if;

  if l.kind = 'relink' then
    select * into p from profiles where id = l.profile_id;
    if p.id is null or not p.active then raise exception 'This login is no longer active.'; end if;
    em := (select email from auth.users where id = p.id);
    perform _set_password(p.id, pw);
  else
    em := coalesce(l.email, 'u' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16) || '@users.servicepro.app');
    uid := _make_login(em, pw, l.full_name);
    insert into profiles (id, org_kind, contractor_id, full_name, email, phone, is_org_admin, can_dispatch, can_bill, is_technician)
    values (uid, 'contractor', l.contractor_id, l.full_name, l.email, l.phone,
            coalesce((l.perms->>'is_org_admin')::boolean, false), coalesce((l.perms->>'can_dispatch')::boolean, false),
            coalesce((l.perms->>'can_bill')::boolean, false), coalesce((l.perms->>'is_technician')::boolean, false))
    returning * into p;
  end if;
  update join_links set used_at = now(), profile_id = p.id where token = l.token;
  return jsonb_build_object('email', em, 'password', pw, 'is_technician', p.is_technician, 'name', p.full_name);
end $$;

-- ---------- Phone alerts and email: the sender picks these up ---------------
create or replace function save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in.'; end if;
  insert into push_subscriptions (endpoint, profile_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set profile_id = excluded.profile_id, p256dh = excluded.p256dh, auth = excluded.auth, failed = 0;
end $$;

create or replace function outbox_take(p_key text, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb;
begin
  if p_key is null or p_key is distinct from (select value from app_secrets where name = 'outbox') then raise exception 'Not allowed.'; end if;
  with picked as (
    select n.id from notifications n where n.sent_at is null and n.created_at > now() - interval '1 day'
     order by n.created_at limit least(greatest(p_limit, 1), 200) for update skip locked),
  sent as (update notifications n set sent_at = now() from picked where n.id = picked.id returning n.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'type', s.type, 'message', s.message,
      'number', (select number from work_orders where id = s.work_order_id), 'work_order_id', s.work_order_id,
      'name', p.full_name, 'email', coalesce(p.email, (select email from auth.users u where u.id = p.id)),
      'portal', case when p.is_technician and not (p.is_org_admin or p.can_dispatch or p.can_bill) then 'tech'
                     when p.contractor_id is not null then 'office' else 'store' end,
      'push', (select coalesce(jsonb_agg(jsonb_build_object('endpoint', ps.endpoint, 'p256dh', ps.p256dh, 'auth', ps.auth)), '[]')
               from push_subscriptions ps where ps.profile_id = p.id and ps.failed < 5))), '[]')
    into out
    from sent s join profiles p on p.id = s.user_id;
  return out;
end $$;

create or replace function outbox_push_failed(p_key text, p_endpoint text, p_gone boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_key is null or p_key is distinct from (select value from app_secrets where name = 'outbox') then raise exception 'Not allowed.'; end if;
  update push_subscriptions set failed = case when p_gone then 99 else failed + 1 end where endpoint = p_endpoint;
end $$;

-- ---------- Fees: Time Verify calls carry no per-call fee (flat per location) --
create or replace function _record_fees(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare w work_orders; cu customers; c contractors; ps platform_settings; mon date; tech uuid;
begin
  select * into w from work_orders where id = p_wo;
  if w.mode = 'verify' then return; end if;
  select * into cu from customers where id = w.customer_id;
  select * into c from contractors where id = w.contractor_id;
  select * into ps from platform_settings;
  mon := date_trunc('month', w.completed_at)::date;
  select technician_id into tech from visits where work_order_id = p_wo and status = 'done' order by visit_no desc limit 1;
  if cu.kind <> 'residential' then
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


-- ---------- Billing: Time Verify stores pay a flat fee per location; reminders say "enter the invoice" ----------
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
  for r in select c.id from customers c where c.kind <> 'residential' and (
             c.plan = 'store_multi' or exists (select 1 from platform_fees f where f.org_kind = 'customer' and f.org_id = c.id and f.billing_month = mon)
             or exists (select 1 from customer_contractors cc where cc.customer_id = c.id and cc.mode = 'verify')) loop
    select * into cu from customers where id = r.id;
    select coalesce(sum(amount) filter (where not waived), 0) into usage
      from platform_fees where org_kind = 'customer' and org_id = r.id and billing_month = mon;
    sub := case when cu.plan = 'store_multi' and not coalesce(cu.fees_waived_until >= mon, false)
                then (select count(*) from sites where customer_id = r.id) * ps.store_multi_per_location
                -- Time Verify: flat per location per month (included in Store Multi)
                when exists (select 1 from customer_contractors cc where cc.customer_id = r.id and cc.mode = 'verify')
                     and not coalesce(cu.fees_waived_until >= mon, false)
                then (select count(*) from sites where customer_id = r.id) * ps.verify_fee_per_site
                else 0 end;
    insert into monthly_statements (org_kind, org_id, billing_month, usage_fees, subscription_fees, total, detail)
    values ('customer', r.id, mon, usage, sub, usage + sub,
            jsonb_build_object('pos', (select count(*) from platform_fees where org_kind = 'customer' and org_id = r.id and billing_month = mon),
              'time_verify_locations', case when cu.plan <> 'store_multi' and exists (select 1 from customer_contractors cc where cc.customer_id = r.id and cc.mode = 'verify') then (select count(*) from sites where customer_id = r.id) end))
    on conflict (org_kind, org_id, billing_month) do update
      set usage_fees = excluded.usage_fees, subscription_fees = excluded.subscription_fees, total = excluded.total, detail = excluded.detail
      where monthly_statements.status = 'draft'
    returning * into st;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function billing_clock() returns int
language plpgsql security definer set search_path = public as $$
declare w record; n int := 0; ps platform_settings;
begin
  select * into ps from platform_settings;
  for w in select * from work_orders where status = 'completed' loop
    if now() >= w.completed_at + make_interval(days => ps.billing_reminder_days) and now() < w.invoice_due_at then
      perform _notify_office(w.id, 'billing_due', format('%s for call #%s is due by %s.',
        case when w.mode = 'verify' then 'Enter the invoice' else 'Invoice' end, w.number,
        to_char(w.invoice_due_at, 'Mon DD')), 'billing_due:' || w.id);
    end if;
    if now() > w.invoice_due_at then
      perform _raise_flag(w.id, 'billing_late', format('Invoice not sent within %s days of completion (due %s).',
        _billing_days(w.id), to_char(w.invoice_due_at, 'Mon DD')), false, true);
      perform _notify_office(w.id, 'billing_overdue', format('OVERDUE: invoice for call #%s was due %s.', w.number,
        to_char(w.invoice_due_at, 'Mon DD')), 'billing_overdue:' || w.id);
      perform _notify_customer(w.id, 'billing_overdue', case when w.mode = 'verify'
        then format('The contractor has not entered the invoice for call #%s yet — it was due %s. You can type it in from their paper or emailed copy.',
          w.number, to_char(w.invoice_due_at, 'Mon DD'))
        else format('The bill for call #%s (about $%s) is late — it was due %s. Expect it soon.',
          w.number, w.total_cost, to_char(w.invoice_due_at, 'Mon DD')) end, 'billing_overdue:' || w.id);
      n := n + 1;
    end if;
  end loop;
  for w in select * from work_orders where response_due_at < now() and first_arrived_at is null
           and status not in ('cancelled','completed','invoiced') loop
    perform _notify_customer(w.id, 'sla_missed', format('Call #%s: the technician has not arrived within your agreement''s response time.', w.number),
      'sla:' || w.id);
    perform _notify_office(w.id, 'sla_missed', format('Call #%s has missed its agreed response time.', w.number), 'sla:' || w.id);
  end loop;
  return n;
end $$;

-- ---------- What the phone downloads: + Time Verify fields, parts runs, calls anyone can take ----------
create or replace function tech_jobs() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); jobs jsonb; cat jsonb; clock jsonb; open_calls jsonb;
begin
  if m.id is null or not m.is_technician then raise exception 'Technicians only.'; end if;
  select coalesce(jsonb_agg(j order by (j->>'sort')), '[]') into jobs from (
    select jsonb_build_object(
      'sort', case v.status when 'on_site' then '0' when 'en_route' then '1' when 'assigned' then '2' else '3' end || coalesce(v.eta_at::text, v.assigned_at::text),
      'visit', jsonb_build_object('id', v.id, 'visit_no', v.visit_no, 'status', v.status, 'assigned_at', v.assigned_at,
         'received_at', v.received_at, 'started_at', v.started_at, 'eta_at', v.eta_at, 'arrived_at', v.arrived_at,
         'checkin_required', v.checkin_required, 'checkin_at', v.checkin_at, 'checkin_verified', v.checkin_verified,
         'completed_at', v.completed_at, 'departed_at', v.departed_at, 'outcome', v.outcome, 'note', v.outcome_note,
         'arrival_source', v.arrival_source,
         'parts_runs', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'supplier', pr.supplier, 'left_at', pr.left_at,
             'at_supplier_at', pr.at_supplier_at, 'returned_at', pr.returned_at) order by pr.left_at), '[]') from parts_runs pr where pr.visit_id = v.id)),
      'wo', jsonb_build_object('id', w.id, 'number', w.number, 'kind', w.kind, 'status', w.status, 'priority', w.priority,
         'problem', w.issue_description, 'issue', it.name, 'unit', w.unit, 'contact_name', w.contact_name,
         'contact_phone', w.contact_phone, 'entry_notes', w.entry_notes, 'after_hours', w.after_hours,
         'checklist', w.checklist, 'checklist_results', w.checklist_results, 'repair_type_id', w.repair_type_id,
         'no_parts_used', w.no_parts_used, 'equipment_id', w.equipment_id, 'po_number', coalesce(w.store_po_number, 'PO' || w.number),
         'equipment_type_code', it.equipment_type_code, 'agreement', a.name, 'summary', w.work_summary,
         'mode', w.mode, 'nte', w.nte, 'scheduled_start', w.scheduled_start, 'scheduled_end', w.scheduled_end, 'accepted_at', w.accepted_at),
      'site', jsonb_build_object('id', s.id, 'name', s.name, 'address', s.address, 'lat', s.lat, 'lon', s.lon,
         'geofence_ft', s.geofence_radius_ft, 'access_notes', s.access_notes, 'timezone', s.timezone,
         'has_backup_code', s.backup_code_hash is not null),
      'customer', cu.name,
      'equipment', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'type', et.name, 'type_code', et.code,
           'manufacturer', e.manufacturer, 'model', e.model, 'serial', e.serial, 'location', e.location_description,
           'refrigerant', e.refrigerant, 'confirmed', e.identity_confirmed) order by e.id = w.equipment_id desc, et.name), '[]')
         from equipment e left join equipment_types et on et.id = e.equipment_type_id where e.site_id = s.id),
      'warranties', (select coalesce(jsonb_agg(jsonb_build_object('equipment_id', x.equipment_id, 'kind', x.kind,
           'ends_on', x.ends_on, 'description', x.description)), '[]')
         from warranties x join equipment e on e.id = x.equipment_id where e.site_id = s.id and x.ends_on >= current_date),
      'history', (select coalesce(jsonb_agg(h order by h->>'date' desc), '[]') from (
           select jsonb_build_object('number', h.number, 'date', h.completed_at::date, 'summary', h.work_summary) h
           from work_orders h where h.site_id = s.id and h.id <> w.id and h.status in ('completed','invoiced')
           order by h.completed_at desc limit 5) hh),
      'po_lines', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'po', po_label(w.id, l.seq), 'seq', l.seq, 'kind', l.kind,
           'amount', l.amount, 'description', l.description, 'status', l.status, 'owner_status', l.owner_status,
           'emergency', l.emergency_preapproved) order by l.seq), '[]') from po_lines l where l.work_order_id = w.id),
      'parts', (select coalesce(jsonb_agg(jsonb_build_object('part_id', pu.part_id, 'name', pt.name, 'qty', pu.quantity,
           'unit_price', pu.unit_price, 'covered', pu.covered, 'source', pu.source)), '[]')
         from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = w.id),
      'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'visit_id', p.visit_id)), '[]')
         from photos p where p.work_order_id = w.id),
      'parts_orders', (select coalesce(jsonb_agg(jsonb_build_object('description', o.description, 'status', o.status,
           'expected_on', o.expected_on)), '[]') from parts_orders o where o.work_order_id = w.id),
      'meter', _meter(w.id),
      'rules', jsonb_build_object(
         'rate', _labor_rate_eff(w.id), 'min_minutes', c.min_labor_minutes, 'increment', c.labor_increment_min,
         'bill_travel', c.bill_travel_time, 'warn_pct', c.po_warn_pct,
         'trip_eff', case when cov.labor or (w.kind = 'pm' and (cov.pm or w.flat_amount > 0)) then 0 else c.trip_charge end,
         'parts_covered', cov.parts, 'parts_disc', cov.parts_disc, 'flat', w.flat_amount,
         'other_labor', (select coalesce(sum(vv.labor_amount), 0) from visits vv where vv.work_order_id = w.id and vv.id <> v.id and vv.status <> 'cancelled'),
         'other_trips', (select count(*) from visits vv where vv.work_order_id = w.id and vv.id <> v.id and vv.status <> 'cancelled' and vv.arrived_at is not null)))
    as j
    from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id
    join customers cu on cu.id = w.customer_id join contractors c on c.id = w.contractor_id
    left join issue_types it on it.id = w.issue_type_id left join agreements a on a.id = w.agreement_id
    cross join lateral _coverage(w.id) cov
    where v.technician_id = m.id and (v.status in ('assigned','en_route','on_site')
          or (v.status = 'done' and v.completed_at > now() - interval '18 hours'))
  ) x(j);

  select jsonb_build_object(
    'equipment_types', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'trade_id', trade_id) order by trade_id, name), '[]')
       from equipment_types where contractor_id is null or contractor_id = m.contractor_id),
    'repair_types', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'trade_id', r.trade_id,
         'equipment_type_codes', r.equipment_type_codes,
         'kit', (select coalesce(jsonb_agg(jsonb_build_object('part_id', rp.part_id, 'qty', rp.quantity)), '[]') from repair_type_parts rp where rp.repair_type_id = r.id))
         order by r.name), '[]') from repair_types r where r.contractor_id = m.contractor_id and r.active),
    'parts', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'sku', p.sku, 'name', p.name, 'category', p.category,
         'price', part_price(p.id)) order by p.category, p.name), '[]') from parts p where p.contractor_id = m.contractor_id and p.active)
  ) into cat;

  select jsonb_build_object('shift', (select jsonb_build_object('id', id, 'start_at', start_at) from time_entries
            where profile_id = m.id and kind = 'shift' and end_at is null order by start_at desc limit 1),
          'brk', (select jsonb_build_object('id', id, 'start_at', start_at) from time_entries
            where profile_id = m.id and kind = 'break' and end_at is null order by start_at desc limit 1)) into clock;

  -- Time Verify calls anyone on the team can take ("I'm going")
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'number', w.number, 'po_number', coalesce(w.store_po_number, 'PO' || w.number),
      'status', w.status, 'priority', w.priority, 'problem', w.issue_description, 'issue', it.name, 'unit', w.unit,
      'customer', cu.name, 'site', jsonb_build_object('id', s.id, 'name', s.name, 'address', s.address, 'lat', s.lat, 'lon', s.lon),
      'created_at', w.created_at, 'accepted_at', w.accepted_at, 'scheduled_start', w.scheduled_start, 'scheduled_end', w.scheduled_end,
      'nte', w.nte, 'return_visit', exists (select 1 from visits x where x.work_order_id = w.id and x.status = 'done'))
      order by w.priority, coalesce(w.scheduled_start, w.created_at)), '[]') into open_calls
    from work_orders w join sites s on s.id = w.site_id join customers cu on cu.id = w.customer_id
    left join issue_types it on it.id = w.issue_type_id
   where w.contractor_id = m.contractor_id and w.mode = 'verify' and w.declined_at is null
     and w.status in ('created','assigned','return_needed','waiting_parts')
     and not exists (select 1 from visits x where x.work_order_id = w.id and x.status in ('assigned','en_route','on_site'));

  return jsonb_build_object('me', jsonb_build_object('id', m.id, 'name', m.full_name, 'phone', m.phone),
    'jobs', jobs, 'catalog', cat, 'clock', clock, 'open_calls', open_calls, 'server_time', now());
end $$;

-- ---------- Store PO log (every call as a PO; exportable) ---------------------
create or replace view po_log with (security_invoker = true) as
select w.id, w.number, coalesce(w.store_po_number, 'PO' || w.number) as po_number, w.customer_id, w.contractor_id, w.site_id,
       s.name as site_name, c.name as contractor_name, w.mode, w.source, w.priority, w.status,
       it.name as problem_type, w.issue_description as problem, w.unit,
       concat_ws(' — ', et.name, e.location_description) as equipment,
       w.nte, w.created_at as opened_at, w.accepted_at, w.scheduled_start, w.declined_at, w.first_arrived_at, w.completed_at,
       (select coalesce(sum(greatest(0, extract(epoch from (coalesce(v.completed_at, v.departed_at, now()) - v.arrived_at)) / 3600)), 0)
          from visits v where v.work_order_id = w.id and v.status <> 'cancelled' and v.arrived_at is not null)::numeric(8,2) as hours_on_site_raw,
       (select count(*) from visits v where v.work_order_id = w.id and v.status <> 'cancelled' and v.arrived_at is not null) as trips,
       ci.invoice_number, ci.total as invoice_total, ci.hours_billed, ci.status as invoice_status,
       (ci.check_result->>'billable_h')::numeric as hours_verified, (ci.check_result->>'unexplained_h')::numeric as hours_unexplained,
       w.total_cost, w.store_confirmed_at, w.store_disputed,
       array(select f.flag::text from guardrail_flags f where f.work_order_id = w.id and f.resolved_at is null and f.visible_to_customer
             order by f.triggered_at) as flags
  from work_orders w
  join sites s on s.id = w.site_id
  join contractors c on c.id = w.contractor_id
  left join issue_types it on it.id = w.issue_type_id
  left join equipment e on e.id = w.equipment_id
  left join equipment_types et on et.id = e.equipment_type_id
  left join call_invoices ci on ci.work_order_id = w.id;

-- ---------- Security ---------------------------------------------------------
alter table trade_contractors enable row level security;
alter table site_report_pins enable row level security;
alter table qr_attempts enable row level security;
alter table parts_runs enable row level security;
alter table call_invoices enable row level security;
alter table join_links enable row level security;
alter table push_subscriptions enable row level security;
alter table app_secrets enable row level security;
revoke all on trade_contractors, site_report_pins, qr_attempts, parts_runs, call_invoices, join_links, push_subscriptions, app_secrets
  from anon, authenticated;
revoke all on po_log from anon, authenticated;
grant select on trade_contractors, parts_runs, call_invoices, join_links, push_subscriptions, po_log to authenticated;

create policy read_tc on trade_contractors for select using (is_customer_member(customer_id)
  or (contractor_id is not null and is_contractor_member(contractor_id)));
create policy read_runs on parts_runs for select using (can_see_work_order(work_order_id));
create policy read_invoices on call_invoices for select using (can_see_work_order(work_order_id));
create policy read_join on join_links for select using (created_by = auth.uid()
  or (kind <> 'contractor_owner' and contractor_id is not null and exists (select 1 from profiles me
        where me.id = auth.uid() and me.contractor_id = join_links.contractor_id and me.is_org_admin))
  or (kind = 'contractor_owner' and customer_id is not null and is_customer_admin(customer_id)));
create policy own_push on push_subscriptions for select using (profile_id = auth.uid());

do $$ declare t text; begin
  foreach t in array array['call_invoices','parts_runs','trade_contractors'] loop
    execute format('create trigger audit_%1$s after insert or update on %1$I for each row execute function _audit()', t);
  end loop;
end $$;
-- call_invoices has no "id" column; the audit row id is the call
create or replace function _audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare j jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into audit_log (table_name, row_id, action, actor, old_data, new_data)
  values (tg_table_name, coalesce(j ->> 'id', j ->> 'work_order_id')::uuid, tg_op, auth.uid(),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return null;
end $$;

do $$ declare f text; begin
  foreach f in array array[
    'open_po_call(uuid,uuid,text,text,numeric,smallint,uuid,uuid,text,uuid)',
    'enter_phone_call(uuid,uuid,text,text,text,text,smallint,uuid,uuid)',
    'accept_call(uuid,text,timestamptz,timestamptz,text)', 'decline_call(uuid,text)', 'reroute_call(uuid,uuid)',
    'store_confirm_call(uuid,boolean,text,text)', 'tech_claim_call(uuid,timestamptz,double precision,double precision)',
    'tech_parts_run(uuid,text,uuid,text,timestamptz,double precision,double precision)',
    'tech_leave(uuid,visit_outcome,text,timestamptz,double precision,double precision)', 'store_tech_here(uuid,text)',
    'verified_hours(uuid)', 'invoice_check(uuid)', 'submit_invoice(uuid,text,numeric,numeric,numeric,text,text,text)',
    'store_review_invoice(uuid,boolean,text)', 'set_contractor_terms(uuid,text,text,int,int)', 'set_my_terms(uuid,numeric,int)',
    'set_trade_contractor(uuid,smallint,uuid)', 'set_report_pin(uuid,text)', 'site_has_report_pin(uuid)',
    'invite_contractor(text,text,text,text,smallint[],uuid[])', 'add_team_member(text,text,text,boolean,boolean)',
    'new_signin_link(uuid)', 'save_push_subscription(text,text,text)', 'tech_jobs()'] loop
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;
-- No-login pages: the QR sticker, the sign-in link, and the alert sender (with its key)
grant execute on function qr_info(uuid), qr_report(uuid,text,uuid,text,text,boolean), join_info(uuid), join_redeem(uuid),
  outbox_take(text,int), outbox_push_failed(text,text,boolean) to anon, authenticated;

-- Contractor office may add a shop-work photo to the invoice
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    execute $p$create policy job_photos_office_add on storage.objects for insert to authenticated
      with check (bucket_id = 'job-photos' and exists (select 1 from public.work_orders w
        where w.id = ((storage.foldername(name))[1])::uuid and public.is_contractor_office(w.contractor_id)))$p$;
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-accept', '*/5 * * * *', 'select public.accept_watch()');
  end if;
end $$;

-- Internal helpers are never called directly by the apps
revoke execute on function _cc(uuid,uuid), _route_contractor(uuid,smallint), _local(timestamptz,uuid,text), _po(work_orders),
  _repeat_check(uuid), _create_call(uuid,uuid,text,uuid,smallint,text,wo_kind,uuid,boolean,uuid,uuid,text,numeric,text),
  _visit_accepts(), accept_watch(), _verified(uuid), _invoice_check(uuid), _make_login(text,text,text), _set_password(uuid,text)
  from public, anon, authenticated;
revoke execute on function monthly_billing_run(date), billing_clock(), _record_fees(uuid), _audit() from anon;
