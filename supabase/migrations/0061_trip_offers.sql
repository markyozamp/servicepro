-- Return trips the customer agrees to: the contractor offers up to 3 times, the customer taps the one that works
-- (or says none work, with a note on what would). Only the picked time gets scheduled, so a tech never shows up
-- in the middle of a lunch rush. "Going now" (and anything within the next 2 hours) still goes straight through.
-- Demo only: the tech's phone in the demo can show the check-in code so the walkthrough can continue.

create table if not exists trip_offers (
  id            uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references work_orders(id) on delete cascade,
  tech_id       uuid not null references profiles(id),
  options       jsonb not null,               -- [{"start": ts, "end": ts|null}, ...] 1 to 3
  note          text,
  status        text not null default 'pending' check (status in ('pending','accepted','declined','replaced','withdrawn')),
  chosen        int,
  store_note    text,
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now(),
  decided_by    uuid,
  decided_at    timestamptz
);
create index if not exists trip_offers_wo on trip_offers(work_order_id);
alter table trip_offers enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'trip_offers' and policyname = 'trip_offers_read') then
    create policy trip_offers_read on trip_offers for select using (can_see_work_order(work_order_id));
  end if;
end $$;
grant select on trip_offers to authenticated;

-- Contractor: offer 1 to 3 times for the next trip
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
revoke execute on function offer_trip_times(uuid, uuid, jsonb, text) from public, anon;
grant execute on function offer_trip_times(uuid, uuid, jsonb, text) to authenticated;

-- Customer: pick one (1, 2 or 3), or none (null) with a note on what would work
create or replace function store_pick_trip_time(p_offer uuid, p_choice int, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); o trip_offers; w work_orders; opt jsonb; v visits;
begin
  select * into o from trip_offers where id = p_offer for update;
  select * into w from work_orders where id = o.work_order_id;
  if o.id is null or m.customer_id is distinct from w.customer_id or not profile_sees_site(m.id, w.site_id) then raise exception 'Not allowed.'; end if;
  if o.status <> 'pending' then raise exception 'This was already answered.'; end if;
  if p_choice is null then
    if nullif(trim(p_note), '') is null then raise exception 'Say what would work, for example "after 2 pm" or "Tuesday morning".'; end if;
    update trip_offers set status = 'declined', store_note = trim(p_note), decided_by = m.id, decided_at = now() where id = p_offer;
    perform _notify_office(w.id, 'assigned', format('Call #%s: %s at the location says none of those times work: "%s". Please offer new times.',
      w.number, m.full_name, trim(p_note)), 'offer-no:' || p_offer);
    return jsonb_build_object('ok', true, 'declined', true);
  end if;
  opt := o.options -> (p_choice - 1);
  if opt is null then raise exception 'Pick one of the times offered.'; end if;
  if (opt->>'start')::timestamptz < now() - interval '15 minutes' then raise exception 'That time has passed. Ask them for new times.'; end if;
  update trip_offers set status = 'accepted', chosen = p_choice, store_note = nullif(trim(p_note), ''), decided_by = m.id, decided_at = now() where id = p_offer;
  perform set_config('app.trip_pick', 'on', true);
  v := schedule_trip(w.id, o.tech_id, (opt->>'start')::timestamptz, (opt->>'end')::timestamptz, o.note);
  perform set_config('app.trip_pick', 'off', true);
  perform _notify_office(w.id, 'assigned', format('Call #%s: %s picked %s. The trip is scheduled.', w.number, m.full_name,
    _local((opt->>'start')::timestamptz, w.site_id, 'Dy Mon DD HH12:MI AM')), 'offer-yes:' || p_offer);
  return jsonb_build_object('ok', true, 'visit_id', v.id);
end $$;
revoke execute on function store_pick_trip_time(uuid, int, text) from public, anon;
grant execute on function store_pick_trip_time(uuid, int, text) to authenticated;

-- schedule_trip: the customer's pick goes through; otherwise a Time Verify trip more than 2 hours out must be offered
select from _patch_fn('schedule_trip(uuid,uuid,timestamptz,timestamptz,text)'::regprocedure,
  'if w.id is null or not is_contractor_dispatcher(w.contractor_id) then',
  'if w.id is null or not (is_contractor_dispatcher(w.contractor_id) or coalesce(current_setting(''app.trip_pick'', true), '''') = ''on'') then');
select from _patch_fn('schedule_trip(uuid,uuid,timestamptz,timestamptz,text)'::regprocedure,
  '  select * into s from sites where id = w.site_id;',
  '  if w.mode = ''verify'' and p_start is not null and p_start > now() + interval ''2 hours'' and coalesce(current_setting(''app.trip_pick'', true), '''') <> ''on'' then' || chr(10) ||
  '    raise exception ''Send the customer times to pick from, so the trip fits their day.'';' || chr(10) ||
  '  end if;' || chr(10) ||
  '  update trip_offers set status = ''withdrawn'' where work_order_id = w.id and status = ''pending'' and coalesce(current_setting(''app.trip_pick'', true), '''') <> ''on'';' || chr(10) ||
  '  select * into s from sites where id = w.site_id;');

-- The location menu lists times to pick
select from _patch_fn('site_attention()'::regprocedure,
  '      select 4, w.created_at, ''confirm''',
  '      select 3, o.created_at, ''trip'', ''trip-'' || o.id,' || chr(10) ||
  '             format(''Pick a time for %s to come back (call #%s)'', (select name from contractors where id = w.contractor_id), w.number)' || chr(10) ||
  '        from trip_offers o join work_orders w on w.id = o.work_order_id' || chr(10) ||
  '       where w.site_id = s.id and o.status = ''pending''' || chr(10) ||
  '      union all' || chr(10) ||
  '      select 4, w.created_at, ''confirm''');

-- Demo only: the demo technician's phone can show the code, so someone trying the phone app can keep going
create or replace function demo_tech_code(p_visit uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v visits;
begin
  if not _demo_actor() then raise exception 'Only in the demo.'; end if;
  select * into v from visits where id = p_visit;
  if v.id is null or v.technician_id is distinct from auth.uid() then raise exception 'Not your job.'; end if;
  if not exists (select 1 from work_orders w join customers c on c.id = w.customer_id where w.id = v.work_order_id and c.name like '%(demo)') then raise exception 'Only in the demo.'; end if;
  return (select code from visit_codes where visit_id = p_visit);
end $$;
revoke execute on function demo_tech_code(uuid) from public, anon;
grant execute on function demo_tech_code(uuid) to authenticated;
