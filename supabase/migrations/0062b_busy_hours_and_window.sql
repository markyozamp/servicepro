-- Busy hours on each location (a restaurant's lunch and dinner rush, a dental office's patient hours) and the
-- customer's "When can they come?" on a call.
-- Busy hours are a hard stop for non-emergency visits: no offering, scheduling, accepting "on the way now" or
-- starting a trip inside them. Emergencies go any time (the customer marked it). Only the customer can let a
-- contractor come during busy hours, per call ("Let them come now"). A tech already on site isn't stopped; the
-- customer gets a heads-up that busy hours are starting.

alter table sites add column if not exists busy_hours jsonb;          -- {"mon":[["11:00","13:30"],["17:00","19:30"]], ...}
alter table customers add column if not exists require_call_window boolean not null default false;
alter table work_orders add column if not exists window_start timestamptz;
alter table work_orders add column if not exists window_end timestamptz;
alter table work_orders add column if not exists window_note text;
alter table work_orders add column if not exists busy_override_at timestamptz;
alter table work_orders add column if not exists busy_override_by uuid;

-- Is the location busy at this moment? Returns {from, to, text} of that busy window, or null.
create or replace function _busy_at(p_site uuid, p_at timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s sites; lt timestamp; r jsonb;
begin
  select * into s from sites where id = p_site;
  if s.busy_hours is null then return null; end if;
  lt := p_at at time zone coalesce(s.timezone, 'America/Chicago');
  for r in select * from jsonb_array_elements(coalesce(s.busy_hours -> lower(to_char(lt, 'dy')), '[]')) loop
    if lt::time >= (r->>0)::time and lt::time < (r->>1)::time then
      return jsonb_build_object('from', r->>0, 'to', r->>1,
        'text', to_char((r->>0)::time, 'FMHH12:MI AM') || '–' || to_char((r->>1)::time, 'FMHH12:MI AM'));
    end if;
  end loop;
  return null;
end $$;

-- First busy window touched between two moments (checked every 15 minutes), or null
create or replace function _busy_between(p_site uuid, p_start timestamptz, p_end timestamptz) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t timestamptz := p_start; b jsonb;
begin
  if p_start is null then return null; end if;
  loop
    b := _busy_at(p_site, t);
    if b is not null then return b; end if;
    t := t + interval '15 minutes';
    exit when p_end is null or t >= p_end or t > p_start + interval '24 hours';
  end loop;
  return null;
end $$;

-- Stop a non-emergency visit inside busy hours (unless the customer allowed it on this call)
create or replace function _busy_guard(p_wo uuid, p_start timestamptz, p_end timestamptz) returns void
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; b jsonb; sname text;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or w.priority = 1 or w.busy_override_at is not null then return; end if;
  b := _busy_between(w.site_id, p_start, p_end);
  if b is null then return; end if;
  sname := (select name from sites where id = w.site_id);
  if p_start <= now() + interval '5 minutes' then
    raise exception '% is in its busy hours (%). You can head over after %, or they can tap "Let them come now" on the call.',
      sname, b->>'text', to_char((b->>'to')::time, 'FMHH12:MI AM');
  end if;
  raise exception '% is busy % (their busy hours). Pick a time outside that.', sname, b->>'text';
end $$;

-- Busy hours in words, for the call and the tech's phone
create or replace function _busy_summary(p_site uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare s sites; d text; parts text[] := '{}'; one text; r jsonb; first text; same boolean := true; out_ text;
begin
  select * into s from sites where id = p_site;
  if s.busy_hours is null then return null; end if;
  foreach d in array array['mon','tue','wed','thu','fri','sat','sun'] loop
    one := null;
    for r in select * from jsonb_array_elements(coalesce(s.busy_hours -> d, '[]')) loop
      one := coalesce(one || ', ', '') || to_char((r->>0)::time, 'FMHH12:MI AM') || '–' || to_char((r->>1)::time, 'FMHH12:MI AM');
    end loop;
    if first is null and d = 'mon' then first := coalesce(one, '-'); elsif coalesce(one, '-') <> first then same := false; end if;
    if one is not null then parts := parts || (initcap(d) || ' ' || one); end if;
  end loop;
  if cardinality(parts) = 0 then return null; end if;
  if same and first <> '-' then return 'Every day ' || first; end if;
  return array_to_string(parts, ' · ');
end $$;

create or replace function _window_text(p_wo uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when w.window_start is null and w.window_note is null then null
              else trim(both ' ' from coalesce(w.window_note, '') ||
                case when w.window_start is not null then ' ' || _local(w.window_start, w.site_id, 'Dy Mon DD HH12:MI AM')
                     || coalesce('–' || _local(w.window_end, w.site_id, 'HH12:MI AM'), '') else '' end) end
  from work_orders w where w.id = p_wo
$$;

-- Customer: busy hours for a location
create or replace function set_busy_hours(p_site uuid, p_hours jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; d text; r jsonb;
begin
  select * into s from sites where id = p_site;
  if s.id is null or m.customer_id is distinct from s.customer_id or not store_can(m.customer_id, 'locations') or not profile_sees_site(m.id, s.id) then
    raise exception 'You don''t have permission to change this location.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if p_hours is not null then
    foreach d in array array['mon','tue','wed','thu','fri','sat','sun'] loop
      for r in select * from jsonb_array_elements(coalesce(p_hours -> d, '[]')) loop
        begin
          if (r->>0)::time >= (r->>1)::time then raise exception 'On %, busy hours have to end after they start.', d; end if;
        exception when invalid_datetime_format or datetime_field_overflow then raise exception 'Use times like 11:00 and 13:30.';
        end;
      end loop;
    end loop;
  end if;
  perform _allow_internal(true);
  update sites set busy_hours = case when p_hours is null or p_hours = '{}'::jsonb then null else p_hours end where id = p_site;
  perform _end_internal();
  return jsonb_build_object('ok', true, 'summary', _busy_summary(p_site));
end $$;
revoke execute on function set_busy_hours(uuid, jsonb) from public, anon;
grant execute on function set_busy_hours(uuid, jsonb) to authenticated;

create or replace function set_require_call_window(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'company') then raise exception 'You don''t have permission to change company settings.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  perform _allow_internal(true);
  update customers set require_call_window = coalesce(p_on, false) where id = m.customer_id;
  perform _end_internal();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function set_require_call_window(boolean) from public, anon;
grant execute on function set_require_call_window(boolean) to authenticated;

-- Customer: "When can they come?" on a call (right after opening it, or later)
create or replace function set_call_window(p_wo uuid, p_start timestamptz, p_end timestamptz, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; b jsonb; txt text;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or m.customer_id is distinct from w.customer_id or not profile_sees_site(m.id, w.site_id) then raise exception 'Not allowed.'; end if;
  if p_end is not null and (p_start is null or p_end <= p_start) then raise exception 'The window has to end after it starts.'; end if;
  if w.priority <> 1 and p_start is not null then
    b := _busy_between(w.site_id, p_start, p_end);
    if b is not null then raise exception 'That overlaps your busy hours (%). Pick a time outside them.', b->>'text'; end if;
  end if;
  perform _allow_internal(true);
  update work_orders set window_start = p_start, window_end = p_end, window_note = nullif(trim(p_note), '') where id = p_wo;
  perform _end_internal();
  txt := _window_text(p_wo);
  if txt is not null then
    perform _notify_office(p_wo, 'new_call', format('Call #%s: the customer asks you to come %s.', w.number, txt), 'window:' || p_wo || ':' || md5(txt));
  end if;
  return jsonb_build_object('ok', true, 'text', txt);
end $$;
revoke execute on function set_call_window(uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function set_call_window(uuid, timestamptz, timestamptz, text) to authenticated;

-- Customer: let the contractor come during busy hours on this one call
create or replace function store_allow_busy(p_wo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or m.customer_id is distinct from w.customer_id or not profile_sees_site(m.id, w.site_id) then raise exception 'Not allowed.'; end if;
  perform _allow_internal(true);
  update work_orders set busy_override_at = now(), busy_override_by = m.id where id = p_wo;
  perform _end_internal();
  perform _notify_office(p_wo, 'new_call', format('Call #%s: %s at the location says you can come during their busy hours.', w.number, m.full_name), 'busyok:' || p_wo);
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function store_allow_busy(uuid) from public, anon;
grant execute on function store_allow_busy(uuid) to authenticated;

-- Every 5 minutes: heads-up when busy hours are about to start with a tech on site; flag emergency visits during busy hours
create or replace function busy_watch() returns int
language plpgsql security definer set search_path = public as $$
declare r record; b jsonb; n int := 0;
begin
  for r in select v.id, v.work_order_id, v.arrived_at, w.site_id, w.number, w.priority, w.busy_override_at, p.full_name tech, s.name site_name
             from visits v join work_orders w on w.id = v.work_order_id join sites s on s.id = w.site_id join profiles p on p.id = v.technician_id
            where v.status = 'on_site' and s.busy_hours is not null loop
    if _busy_at(r.site_id, now()) is null then
      b := _busy_at(r.site_id, now() + interval '15 minutes');
      if b is not null then
        perform _notify_customer(r.work_order_id, 'arrival', format('%s is still on site at %s (call #%s). Your busy hours start at %s.',
          r.tech, r.site_name, r.number, to_char((b->>'from')::time, 'FMHH12:MI AM')), 'busystart:' || r.id || ':' || current_date || ':' || (b->>'from'));
        n := n + 1;
      end if;
    end if;
    b := _busy_at(r.site_id, r.arrived_at);
    if b is not null and r.priority = 1 and r.busy_override_at is null
       and not exists (select 1 from guardrail_flags g where g.work_order_id = r.work_order_id and g.flag = 'busy_hours_visit') then
      perform _raise_flag(r.work_order_id, 'busy_hours_visit', format('%s arrived at %s, during your busy hours (%s), on an emergency call.',
        r.tech, _local(r.arrived_at, r.site_id, 'HH12:MI AM'), b->>'text'), false, true);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function busy_watch() from public, anon, authenticated;

-- Offers: no offered time inside busy hours
create or replace function offer_trip_times(p_wo uuid, p_tech uuid, p_options jsonb, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; t profiles; o jsonb; n int; nid uuid; txt text := ''; i int := 0;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not is_contractor_dispatcher(w.contractor_id) then raise exception 'Only your office (or the owner) can schedule trips.'; end if;
  if w.status in ('completed','invoiced','cancelled') then raise exception 'This call is closed.'; end if;
  select * into t from profiles where id = p_tech and is_technician and active and contractor_id = w.contractor_id;
  if t.id is null then raise exception 'Pick one of your active technicians.'; end if;
  n := coalesce(jsonb_array_length(p_options), 0);
  if n < 1 or n > 3 then raise exception 'Offer 1 to 3 times.'; end if;
  for o in select * from jsonb_array_elements(p_options) loop
    i := i + 1;
    if (o->>'start') is null then raise exception 'Each time needs a start.'; end if;
    if (o->>'start')::timestamptz < now() then raise exception 'Time % has already passed.', i; end if;
    if (o->>'end') is not null and (o->>'end')::timestamptz <= (o->>'start')::timestamptz then raise exception 'Time % must end after it starts.', i; end if;
    perform _busy_guard(p_wo, (o->>'start')::timestamptz + interval '6 minutes', (o->>'end')::timestamptz);
    txt := txt || case when i > 1 then '; ' else '' end || _local((o->>'start')::timestamptz, w.site_id, 'Dy Mon DD HH12:MI AM')
           || coalesce('–' || _local((o->>'end')::timestamptz, w.site_id, 'HH12:MI AM'), '');
  end loop;
  update trip_offers set status = 'replaced' where work_order_id = p_wo and status = 'pending';
  insert into trip_offers (work_order_id, tech_id, options, note, created_by) values (p_wo, p_tech, p_options, nullif(trim(p_note), ''), m.id) returning id into nid;
  perform _notify_customer(p_wo, 'assigned', format('%s wants to come back for call #%s at %s. Pick a time that works for you: %s.%s',
    (select name from contractors where id = w.contractor_id), w.number, (select name from sites where id = w.site_id), txt,
    coalesce(' ' || nullif(trim(p_note), ''), '')), 'offer:' || nid);
  return jsonb_build_object('ok', true, 'id', nid);
end $$;

-- The guard on every way a contractor gets a tech there
select from _patch_fn('schedule_trip(uuid,uuid,timestamptz,timestamptz,text)'::regprocedure,
  '  select * into s from sites where id = w.site_id;',
  '  if coalesce(current_setting(''app.trip_pick'', true), '''') <> ''on'' then perform _busy_guard(w.id, coalesce(p_start, now()), p_end); end if;' || chr(10) ||
  '  select * into s from sites where id = w.site_id;');
select from _patch_fn('accept_call(uuid,text,timestamptz,timestamptz,text)'::regprocedure,
  '  if p_when = ''scheduled'' then' || chr(10),
  '  perform _busy_guard(w.id, case when p_when = ''scheduled'' then p_start else now() end, case when p_when = ''scheduled'' then p_end end);' || chr(10) ||
  '  if p_when = ''scheduled'' then' || chr(10));
select from _patch_fn('tech_claim_call(uuid,timestamptz,double precision,double precision)'::regprocedure,
  '  if w.declined_at is not null then raise exception ''Your office declined this call.''; end if;' || chr(10),
  '  if w.declined_at is not null then raise exception ''Your office declined this call.''; end if;' || chr(10) ||
  '  perform _busy_guard(w.id, t, null);' || chr(10));
select from _patch_fn('tech_start(uuid,timestamptz,double precision,double precision)'::regprocedure,
  ' if v.status <> ''assigned'' then return v; end if; -- duplicate sync' || chr(10),
  ' if v.status <> ''assigned'' then return v; end if; -- duplicate sync' || chr(10) ||
  ' perform _busy_guard(v.work_order_id, t, null);' || chr(10));

-- The tech's phone shows busy hours and the customer's requested time
select from _patch_fn('tech_jobs()'::regprocedure,
  '''contact_phone'', w.contact_phone, ''entry_notes'', w.entry_notes, ''after_hours'', w.after_hours,',
  '''contact_phone'', w.contact_phone, ''entry_notes'', w.entry_notes, ''after_hours'', w.after_hours, ''busy_hours'', _busy_summary(w.site_id), ''window'', _window_text(w.id), ''busy_ok'', w.busy_override_at is not null,');

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-busy-watch', '*/5 * * * *', 'select public.busy_watch()');
  end if;
end $$;
