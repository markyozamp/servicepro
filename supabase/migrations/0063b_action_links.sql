-- Getting people to act on what's waiting on them.
-- 1) One-tap links: the alert email carries a link that opens that one thing (pick a time, confirm a crew, approve
--    a repair or an invoice, confirm a call, let a contractor in during busy hours, see the check-in code), already
--    signed in as that person. Only that person, only that item; it stops working once used or after 3 days.
-- 2) Reminders that move up the chain: urgent items remind after 15 min and go to the location's backup person after
--    30; routine items remind after 4 hours (daytime) and go to the backup the next morning. No backup set: the
--    company's admins. Nothing is decided automatically.
-- 3) "Ask to come now": a contractor stopped by busy hours can ask the location instead of phoning around.

-- ============ Who to go to when nobody at a location answers ============
-- (No foreign key to profiles on purpose: a second sites-profiles link would confuse the app's joins.)
alter table sites add column if not exists backup_profile_id uuid;
grant select (backup_profile_id) on sites to authenticated;

create or replace function set_site_backup(p_site uuid, p_profile uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; p profiles;
begin
  select * into s from sites where id = p_site;
  if s.id is null or m.customer_id is distinct from s.customer_id or not (m.is_org_admin or m.can_manage_locations) then
    raise exception 'Only your admin or someone who manages locations can change this.';
  end if;
  if p_profile is not null then
    select * into p from profiles where id = p_profile and active and customer_id = s.customer_id;
    if p.id is null then raise exception 'Pick someone on your team.'; end if;
    if not profile_sees_site(p.id, s.id) then raise exception '% can''t see %. Give them that location first.', p.full_name, s.name; end if;
  end if;
  update sites set backup_profile_id = p_profile where id = p_site;
  return jsonb_build_object('ok', true, 'name', p.full_name);
end $$;

-- ============ Contractor asks to come during busy hours ============
alter table work_orders add column if not exists busy_ask_at timestamptz;
alter table work_orders add column if not exists busy_ask_by uuid;
alter table work_orders add column if not exists busy_ask_note text;
alter table work_orders add column if not exists busy_ask_answer text;
alter table work_orders add column if not exists busy_ask_answered_at timestamptz;
alter table work_orders add column if not exists busy_ask_answered_by uuid;

create or replace function ask_busy_ok(p_wo uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or m.contractor_id is null or m.contractor_id is distinct from w.contractor_id then raise exception 'Not allowed.'; end if;
  if w.status in ('completed', 'invoiced', 'cancelled') then raise exception 'This call is closed.'; end if;
  if w.priority = 1 or w.busy_override_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  if w.busy_ask_at > now() - interval '10 minutes' and w.busy_ask_answered_at is null then
    raise exception 'You already asked. They have been reminded; you''ll hear as soon as they answer.';
  end if;
  perform _allow_internal(true);
  update work_orders set busy_ask_at = now(), busy_ask_by = m.id, busy_ask_note = nullif(trim(p_note), ''),
         busy_ask_answer = null, busy_ask_answered_at = null, busy_ask_answered_by = null where id = p_wo;
  perform _end_internal();
  perform _notify_customer(p_wo, 'waiting', format('Call #%s: %s (%s) asks to come now, during your busy hours%s. Let them come, or not yet?',
    w.number, m.full_name, (select name from contractors where id = w.contractor_id), coalesce(': ' || nullif(trim(p_note), ''), '')),
    'busyask:' || p_wo || ':' || extract(epoch from now())::bigint);
  return jsonb_build_object('ok', true);
end $$;

create or replace function store_decline_busy(p_wo uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or m.customer_id is distinct from w.customer_id or not profile_sees_site(m.id, w.site_id) then raise exception 'Not allowed.'; end if;
  if w.busy_ask_at is null or w.busy_ask_answered_at is not null then raise exception 'There''s no open request on this call.'; end if;
  perform _allow_internal(true);
  update work_orders set busy_ask_answer = 'no', busy_ask_answered_at = now(), busy_ask_answered_by = m.id where id = p_wo;
  perform _end_internal();
  perform _notify_office(p_wo, 'new_call', format('Call #%s: %s at the location says not during their busy hours%s. Come after: %s.',
    w.number, m.full_name, coalesce(' (' || nullif(trim(p_note), '') || ')', ''), coalesce(_busy_summary(w.site_id), 'their busy hours')),
    'busyno:' || p_wo || ':' || extract(epoch from now())::bigint);
  return jsonb_build_object('ok', true);
end $$;

select from _patch_fn('store_allow_busy(uuid)'::regprocedure,
  'update work_orders set busy_override_at = now(), busy_override_by = m.id where id = p_wo;',
  'update work_orders set busy_override_at = now(), busy_override_by = m.id,
         busy_ask_answer = case when busy_ask_at is not null and busy_ask_answered_at is null then ''yes'' else busy_ask_answer end,
         busy_ask_answered_at = case when busy_ask_at is not null and busy_ask_answered_at is null then now() else busy_ask_answered_at end,
         busy_ask_answered_by = case when busy_ask_at is not null and busy_ask_answered_at is null then m.id else busy_ask_answered_by end
   where id = p_wo;');

select from _patch_fn('_busy_guard(uuid, timestamptz, timestamptz)'::regprocedure,
  'or they can tap "Let them come now" on the call.',
  'or tap "Ask to come now" on the call to send them the request.');

-- ============ What's waiting on a location right now ============
create or replace function _waiting_open()
returns table (kind text, ref uuid, site_id uuid, customer_id uuid, work_order_id uuid, urgent boolean, since timestamptz, label text, target text)
language sql stable security definer set search_path = public as $$
  select 'door', v.id, w.site_id, w.customer_id, w.id, true, v.arrived_at,
         format('%s is at the door for call #%s: give the check-in code', p.full_name, w.number), 'door-' || v.id
    from visits v join work_orders w on w.id = v.work_order_id join profiles p on p.id = v.technician_id
   where v.status = 'on_site' and v.checkin_required and v.checkin_at is null
  union all
  select 'crew', v.id, w.site_id, w.customer_id, w.id, true, v.crew_set_at,
         format('Confirm %s''s crew on call #%s (%s)', p.full_name, w.number, case v.crew_helpers when 1 then '1 helper' else v.crew_helpers || ' helpers' end),
         'crew-' || v.id
    from visits v join work_orders w on w.id = v.work_order_id join profiles p on p.id = v.technician_id
   where v.status = 'on_site' and v.crew_set_at is not null and v.crew_confirmed is null and v.crew_helpers > 0
  union all
  select 'approval', l.id, w.site_id, w.customer_id, w.id,
         w.priority = 1 or exists (select 1 from visits x where x.work_order_id = w.id and x.status = 'on_site'),
         l.requested_at, format('Approve $%s more on call #%s: %s', trim_scale(l.amount), w.number, left(l.description, 60)), 'appr-' || l.id
    from po_lines l join work_orders w on w.id = l.work_order_id
   where l.status = 'pending' and coalesce(l.owner_status, '') <> 'pending'
  union all
  select 'trip', o.id, w.site_id, w.customer_id, w.id, false, o.created_at,
         format('Pick a time for %s to come back (call #%s)', c.name, w.number), 'trip-' || o.id
    from trip_offers o join work_orders w on w.id = o.work_order_id left join contractors c on c.id = w.contractor_id
   where o.status = 'pending'
  union all
  select 'confirm', w.id, w.site_id, w.customer_id, w.id, false, w.created_at,
         format('Confirm call #%s that %s entered', w.number, c.name), 'confirm-' || w.id
    from work_orders w left join contractors c on c.id = w.contractor_id
   where w.source = 'contractor' and w.mode = 'verify' and w.store_confirmed_at is null and not coalesce(w.store_disputed, false)
     and w.status <> 'cancelled'
  union all
  select 'invoice', w.id, w.site_id, w.customer_id, w.id, false, i.entered_at,
         format('Review %s''s invoice %s for call #%s ($%s)', c.name, i.invoice_number, w.number, trim_scale(i.total)), 'call-' || w.id
    from call_invoices i join work_orders w on w.id = i.work_order_id left join contractors c on c.id = w.contractor_id
   where i.status = 'submitted' and i.entered_side = 'contractor'
  union all
  select 'busy', w.id, w.site_id, w.customer_id, w.id, true, w.busy_ask_at,
         format('%s asks to come now, during your busy hours (call #%s)', c.name, w.number), 'call-' || w.id
    from work_orders w left join contractors c on c.id = w.contractor_id
   where w.busy_ask_at is not null and w.busy_ask_answered_at is null and w.busy_override_at is null
     and w.status not in ('completed', 'invoiced', 'cancelled')
$$;
revoke execute on function _waiting_open() from public, anon, authenticated;

-- Who at the location can answer it
create or replace function _waiting_people(p_kind text, p_site uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select p.id from profiles p join sites s on s.id = p_site
   where p.customer_id = s.customer_id and p.active and profile_sees_site(p.id, p_site)
     and case p_kind when 'approval' then p.can_approve
                     when 'invoice' then p.can_see_billing or p.can_approve or p.is_org_admin
                     when 'confirm' then p.can_open_calls or p.can_approve or p.is_org_admin
                     else true end
$$;
revoke execute on function _waiting_people(text, uuid) from public, anon, authenticated;

create or replace function _action_button(p_kind text) returns text language sql immutable as $$
  select case p_kind when 'door' then 'Show the check-in code' when 'crew' then 'Confirm the crew'
    when 'approval' then 'Approve or decline' when 'trip' then 'Pick a time' when 'confirm' then 'Confirm the call'
    when 'invoice' then 'Review the invoice' when 'busy' then 'Let them come, or not yet' else 'Open it' end
$$;

-- ============ One-tap links ============
create table if not exists action_links (
  token       uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references profiles(id) on delete cascade,
  kind        text not null,
  ref         uuid not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '3 days',
  opened_at   timestamptz,
  used_at     timestamptz,
  used_action text,
  used_from   text,
  unique (profile_id, kind, ref)
);
alter table action_links enable row level security;   -- no policies: nobody reads it directly, only through the functions below

create or replace function _action_link(p_profile uuid, p_kind text, p_ref uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  insert into action_links (profile_id, kind, ref) values (p_profile, p_kind, p_ref)
  on conflict (profile_id, kind, ref) do update set expires_at = greatest(action_links.expires_at, now() + interval '3 days')
    where action_links.used_at is null
  returning token into t;
  if t is null then select token into t from action_links where profile_id = p_profile and kind = p_kind and ref = p_ref; end if;
  return t;
end $$;
revoke execute on function _action_link(uuid, text, uuid) from public, anon, authenticated;

-- A waiting-on-you alert that carries its one-tap link
alter table notifications add column if not exists action_kind text;
alter table notifications add column if not exists action_ref uuid;

create or replace function _notify_action(p_user uuid, p_wo uuid, p_msg text, p_dedupe text, p_kind text, p_ref uuid) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, work_order_id, type, message, dedupe_key, action_kind, action_ref)
  select p_user, p_wo, 'waiting', p_msg, p_dedupe, p_kind, p_ref
   where p_user is not null and _wants(p_user, 'waiting')
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing
$$;
revoke execute on function _notify_action(uuid, uuid, text, text, text, uuid) from public, anon, authenticated;

create or replace function _wo_of(p_kind text, p_ref uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select case
    when p_kind in ('door', 'crew') then (select work_order_id from visits where id = p_ref)
    when p_kind = 'approval' then (select work_order_id from po_lines where id = p_ref)
    when p_kind = 'trip' then (select work_order_id from trip_offers where id = p_ref)
    else p_ref end
$$;

-- What the link page shows (no login: the link is the key)
create or replace function action_link_info(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l action_links; p profiles; o record; w work_orders; s sites; cname text; d jsonb := '{}'; v record; po record; inv call_invoices; t record;
begin
  select * into l from action_links where token = p_token;
  if l.token is null then return null; end if;
  select * into p from profiles where id = l.profile_id and active;
  if p.id is null then return null; end if;
  if l.used_at is null and l.expires_at < now() then return jsonb_build_object('expired', true); end if;
  update action_links set opened_at = coalesce(opened_at, now()) where token = p_token;
  select * into o from _waiting_open() x where x.kind = l.kind and x.ref = l.ref;
  select * into w from work_orders where id = _wo_of(l.kind, l.ref);
  select * into s from sites where id = w.site_id;
  select name into cname from contractors where id = w.contractor_id;
  if l.kind in ('door', 'crew') then
    select vv.arrived_at, vv.crew_helpers, vv.crew_names, pp.full_name tech, (select code from visit_codes where visit_id = vv.id) code
      into v from visits vv left join profiles pp on pp.id = vv.technician_id where vv.id = l.ref;
    d := jsonb_build_object('tech', v.tech, 'arrived_at', v.arrived_at, 'helpers', v.crew_helpers, 'helper_names', v.crew_names,
                            'code', case when l.kind = 'door' and o.kind is not null then v.code end);
  elsif l.kind = 'approval' then
    select pl.amount, pl.description, pl.kind, pl.requested_at into po from po_lines pl where pl.id = l.ref;
    d := jsonb_build_object('amount', po.amount, 'description', po.description, 'po_kind', po.kind, 'nte', w.nte,
                            'total_after', _total_with(l.ref), 'my_limit', p.approval_limit, 'can_approve', p.can_approve);
  elsif l.kind = 'trip' then
    select tt.options, tt.note, pp.full_name tech into t from trip_offers tt left join profiles pp on pp.id = tt.tech_id where tt.id = l.ref;
    d := jsonb_build_object('options', t.options, 'note', t.note, 'tech', t.tech, 'busy_hours', _busy_summary(w.site_id));
  elsif l.kind = 'invoice' then
    select * into inv from call_invoices where work_order_id = w.id;
    d := jsonb_build_object('invoice_number', inv.invoice_number, 'total', inv.total, 'hours_billed', inv.hours_billed,
                            'agreed_hours', inv.agreed_hours, 'agreed_cap', inv.agreed_cap, 'nte', w.nte);
  elsif l.kind = 'busy' then
    d := jsonb_build_object('note', w.busy_ask_note, 'asked_at', w.busy_ask_at, 'busy_hours', _busy_summary(w.site_id),
                            'who', (select full_name from profiles where id = w.busy_ask_by));
  elsif l.kind = 'confirm' then
    d := jsonb_build_object('po_number', w.store_po_number, 'created_at', w.created_at);
  end if;
  return jsonb_build_object('kind', l.kind, 'open', o.kind is not null, 'used_at', l.used_at, 'used_action', l.used_action,
    'name', p.full_name, 'site', s.name, 'call_number', w.number, 'call_id', w.id, 'contractor', cname,
    'problem', w.issue_description, 'unit', w.unit, 'label', o.label, 'urgent', o.urgent, 'button', _action_button(l.kind),
    'details', d);
end $$;

-- Answer it from the link, as that person (their own permissions and limits apply, and their name is recorded)
create or replace function action_link_do(p_token uuid, p_choice text, p_option int default null, p_note text default null, p_po text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l action_links; p profiles; prev text; res jsonb;
begin
  select * into l from action_links where token = p_token for update;
  if l.token is null then raise exception 'This link is not valid.'; end if;
  if l.used_at is not null then raise exception 'You already answered this one.'; end if;
  if l.expires_at < now() then raise exception 'This link has expired. Open Service Call Proof to answer it.'; end if;
  select * into p from profiles where id = l.profile_id and active;
  if p.id is null then raise exception 'This link is not valid.'; end if;
  if not exists (select 1 from _waiting_open() x where x.kind = l.kind and x.ref = l.ref) then
    raise exception 'Someone already took care of this. Nothing more to do.';
  end if;
  prev := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claim.sub', p.id::text, true);
  if l.kind = 'crew' then
    res := store_confirm_crew(l.ref, p_choice = 'yes');
  elsif l.kind = 'approval' then
    res := decide_po_line(l.ref, p_choice = 'approve', p_note);
  elsif l.kind = 'trip' then
    res := store_pick_trip_time(l.ref, case when p_choice = 'none' then null else p_option end, p_note);
  elsif l.kind = 'confirm' then
    perform store_confirm_call(l.ref, p_choice = 'yes', p_po, p_note); res := jsonb_build_object('ok', true);
  elsif l.kind = 'invoice' then
    perform store_review_invoice(l.ref, p_choice = 'approve', p_note); res := jsonb_build_object('ok', true);
  elsif l.kind = 'busy' then
    res := case when p_choice = 'yes' then store_allow_busy(l.ref) else store_decline_busy(l.ref, p_note) end;
  else
    raise exception 'Nothing to answer here.';
  end if;
  perform set_config('request.jwt.claim.sub', coalesce(prev, ''), true);
  update action_links set used_at = now(), used_action = p_choice, used_from = _request_from() where token = p_token;
  return jsonb_build_object('ok', true, 'result', res);
end $$;

grant execute on function action_link_info(uuid) to anon, authenticated;
grant execute on function action_link_do(uuid, text, int, text, text) to anon, authenticated;

-- ============ Reminders and going up the chain ============
create table if not exists waiting_log (
  kind          text not null,
  ref           uuid not null,
  site_id       uuid not null,
  work_order_id uuid,
  urgent        boolean not null default false,
  label         text,
  first_seen    timestamptz not null default now(),
  reminded_at   timestamptz,
  escalated_at  timestamptz,
  escalated_to  uuid[],
  done_at       timestamptz,
  primary key (kind, ref)
);
alter table waiting_log enable row level security;   -- no policies: the watcher's own notes

create or replace function _age_text(p_since timestamptz) returns text language sql stable as $$
  select case when now() - p_since < interval '90 minutes' then greatest(1, extract(epoch from now() - p_since)::int / 60) || ' min'
              when now() - p_since < interval '36 hours' then round(extract(epoch from now() - p_since) / 3600) || ' hours'
              else round(extract(epoch from now() - p_since) / 86400) || ' days' end
$$;

create or replace function waiting_watch() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; loc timestamp; who uuid[]; u uuid; open_now text[];
begin
  -- New (or back again)
  insert into waiting_log (kind, ref, site_id, work_order_id, urgent, label)
  select o.kind, o.ref, o.site_id, o.work_order_id, o.urgent, o.label
    from _waiting_open() o join customers c on c.id = o.customer_id
   where c.name not like '%(demo)' or coalesce(current_setting('app.watch_demo', true), '') = 'on'   -- (the tests turn the demo on)
  on conflict (kind, ref) do update set urgent = excluded.urgent, label = excluded.label,
    first_seen = case when waiting_log.done_at is not null then now() else waiting_log.first_seen end,
    reminded_at = case when waiting_log.done_at is not null then null else waiting_log.reminded_at end,
    escalated_at = case when waiting_log.done_at is not null then null else waiting_log.escalated_at end,
    escalated_to = case when waiting_log.done_at is not null then null else waiting_log.escalated_to end,
    done_at = null;
  open_now := array(select o.kind || ':' || o.ref from _waiting_open() o);

  -- Taken care of
  update waiting_log l set done_at = now()
   where l.done_at is null and not (l.kind || ':' || l.ref = any(open_now));

  for r in select l.*, s.name site_name, coalesce(s.timezone, 'America/Chicago') tz, s.backup_profile_id, s.customer_id
             from waiting_log l join sites s on s.id = l.site_id where l.done_at is null loop
    loc := now() at time zone r.tz;
    -- Reminder to the people who can answer it
    if r.reminded_at is null and (
         (r.urgent and r.first_seen <= now() - interval '15 minutes')
      or (not r.urgent and r.first_seen <= now() - interval '4 hours' and extract(hour from loc) between 8 and 19)) then
      for u in select _waiting_people(r.kind, r.site_id) loop
        perform _notify_action(u, r.work_order_id, format('Reminder, still waiting on you (%s): %s.', _age_text(r.first_seen), r.label),
          'wr:' || r.kind || ':' || r.ref || ':' || extract(epoch from r.first_seen)::bigint, r.kind, r.ref);
        n := n + 1;
      end loop;
      update waiting_log set reminded_at = now() where kind = r.kind and ref = r.ref;
    -- Nobody answered: up to the backup person (or the company's admins)
    elsif r.reminded_at is not null and r.escalated_at is null and (
         (r.urgent and r.first_seen <= now() - interval '30 minutes')
      or (not r.urgent and loc::date > (r.first_seen at time zone r.tz)::date and extract(hour from loc) >= 8
          and r.reminded_at <= now() - interval '1 hour')) then
      who := array(select id from profiles where id = r.backup_profile_id and active and customer_id = r.customer_id
                     and profile_sees_site(id, r.site_id));
      if cardinality(who) = 0 then
        who := array(select id from profiles where customer_id = r.customer_id and active and is_org_admin);
      end if;
      foreach u in array who loop
        perform _notify_action(u, r.work_order_id, format('No one at %s has answered in %s: %s.', r.site_name, _age_text(r.first_seen), r.label),
          'we:' || r.kind || ':' || r.ref || ':' || extract(epoch from r.first_seen)::bigint, r.kind, r.ref);
        n := n + 1;
      end loop;
      update waiting_log set escalated_at = now(), escalated_to = who where kind = r.kind and ref = r.ref;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function waiting_watch() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-waiting', '*/2 * * * *', 'select public.waiting_watch()');
  end if;
end $$;

-- ============ The outbox puts the one-tap link on alerts ============
-- A store person's alert about a call that has something waiting on them carries the link to answer it.
create or replace function _alert_action(p_user uuid, p_wo uuid, p_kind text, p_ref uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  if not exists (select 1 from profiles where id = p_user and customer_id is not null) then return null; end if;
  select x.kind, x.ref into o from _waiting_open() x
   where (p_ref is not null and x.kind = p_kind and x.ref = p_ref)
      or (p_ref is null and p_wo is not null and x.work_order_id = p_wo and p_user in (select _waiting_people(x.kind, x.site_id)))
   order by (p_ref is not null and x.kind = p_kind and x.ref = p_ref) desc, x.urgent desc, x.since limit 1;
  if o.kind is null then return null; end if;
  return jsonb_build_object('token', _action_link(p_user, o.kind, o.ref), 'label', _action_button(o.kind));
end $$;
revoke execute on function _alert_action(uuid, uuid, text, uuid) from public, anon, authenticated;

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
      'action', _alert_action(p.id, s.work_order_id, s.action_kind, s.action_ref),
      'push', (select coalesce(jsonb_agg(jsonb_build_object('endpoint', ps.endpoint, 'p256dh', ps.p256dh, 'auth', ps.auth)), '[]')
               from push_subscriptions ps where ps.profile_id = p.id and ps.failed < 5))), '[]')
    into out
    from sent s join profiles p on p.id = s.user_id;
  return out;
end $$;

-- ============ The location menu / "Waiting on you" list ============
-- Same alerts as before, now with when each started and whether it's waiting on an answer.
create or replace function site_attention() returns jsonb
language sql stable security definer set search_path = public as $$
  with wait as materialized (select * from _waiting_open())
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('site_id', s.id, 'name', s.name, 'reasons', array_remove(array[
      case when exists (select 1 from wait where wait.site_id = s.id and wait.kind = 'door') then 'A technician is waiting for the check-in code' end,
      case when exists (select 1 from wait where wait.site_id = s.id and wait.kind = 'approval') then 'Waiting for your approval' end,
      case when exists (select 1 from wait where wait.site_id = s.id and wait.kind in ('crew', 'trip', 'confirm', 'invoice', 'busy'))
           then 'Waiting on your answer' end,
      case when exists (select 1 from work_orders w where w.site_id = s.id and w.status = 'completed' and w.invoice_due_at < now()
             and (w.bill_requested_at is null or w.bill_requested_at < now() - interval '2 days'))
           then 'A contractor''s invoice is late' end,
      case when exists (select 1 from visits v join work_orders w on w.id = v.work_order_id where w.site_id = s.id and v.status = 'assigned'
             and v.missed_alert_at is not null) then 'A technician missed their window' end,
      case when exists (select 1 from site_visitors sv where sv.site_id = s.id and sv.recorded_at > now() - interval '24 hours' and sv.resolved_at is null)
           then 'Unscheduled visitor today' end,
      case when exists (select 1 from guardrail_flags g join work_orders w on w.id = g.work_order_id where w.site_id = s.id
             and g.resolved_at is null and g.visible_to_customer and g.flag <> 'billing_late' and g.store_ack_at is null) then 'A call is flagged for review' end
    ], null),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('kind', i.kind, 'target', i.target, 'label', i.label, 'at', i.at,
                                                            'waiting', i.waiting, 'urgent', i.urgent) order by i.ord, i.at), '[]'::jsonb) from (
      select case wait.kind when 'door' then 1 when 'crew' then 2 when 'busy' then 2 when 'approval' then 3 when 'trip' then 3 else 4 end ord,
             wait.since at, wait.kind, wait.target, wait.label, true waiting, wait.urgent
        from wait where wait.site_id = s.id
      union all
      select 5, w.accept_due_at, 'notaccepted', 'nacc-' || w.id,
             format('Call #%s: %s %s', w.number, (select name from contractors where id = w.contractor_id),
                    case when w.declined_at is not null then 'can''t take it' else 'hasn''t accepted it' end), false, false
        from work_orders w
       where w.site_id = s.id and w.mode = 'verify' and w.status = 'created'
         and ((w.accepted_at is null and w.accept_due_at < now()) or w.declined_at is not null)
      union all
      select 6, v.missed_alert_at, 'missed', 'presence',
             format('%s missed their window for call #%s', p.full_name, w.number), false, false
        from visits v join work_orders w on w.id = v.work_order_id join profiles p on p.id = v.technician_id
       where w.site_id = s.id and v.status = 'assigned' and v.missed_alert_at is not null
      union all
      select 7, sv.recorded_at, 'visitor', 'visitor-' || sv.id,
             format('Unscheduled visitor: %s%s', coalesce(sv.visitor_name, 'someone'), coalesce(' (' || sv.company || ')', '')), false, false
        from site_visitors sv
       where sv.site_id = s.id and sv.recorded_at > now() - interval '24 hours' and sv.resolved_at is null
      union all
      select 8, min(g.triggered_at), 'flag', 'flag-' || w.id,
             format('Call #%s is flagged for review (%s)', w.number, count(*) || case when count(*) = 1 then ' item' else ' items' end), false, false
        from guardrail_flags g join work_orders w on w.id = g.work_order_id
       where w.site_id = s.id and g.resolved_at is null and g.visible_to_customer and g.flag <> 'billing_late' and g.store_ack_at is null
       group by w.id, w.number
      union all
      select 9, w.invoice_due_at, 'late', 'late-' || w.id,
             format('Invoice not received: call #%s (%s)', w.number, (select name from contractors where id = w.contractor_id)), false, false
        from work_orders w
       where w.site_id = s.id and w.status = 'completed' and w.invoice_due_at < now()
         and (w.bill_requested_at is null or w.bill_requested_at < now() - interval '2 days')
    ) i)) as x
    from sites s join profiles me on me.id = auth.uid() and me.active and me.customer_id = s.customer_id
    where profile_sees_site(me.id, s.id)
  ) t
$$;
