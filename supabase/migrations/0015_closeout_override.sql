-- ServicePro 0015 — Close out a visit without the usual paperwork (photos, equipment, repair, parts,
-- check-in), when the situation on site makes it impossible — with a reason, and someone's approval:
--   * the tech calls the office; the office issues a one-time override code and reads it to the tech, or
--   * the tech is the company owner (sole operator): they approve it themselves with their password.
-- Money rules are never overridden: a pending approval or a cost over the approved limit still blocks.
-- The store sees the reason and who approved it on the call.

alter type flag_type add value if not exists 'closeout_override';

create table closeout_overrides (
  id            uuid primary key default gen_random_uuid(),
  visit_id      uuid not null references visits(id) on delete cascade,
  work_order_id uuid not null references work_orders(id) on delete cascade,
  code          text,                                   -- office route: one-time code read to the tech
  office_reason text,                                   -- what the tech told the office
  issued_by     uuid references profiles(id),
  issued_at     timestamptz,
  used_at       timestamptz,
  reason        text,                                   -- reason picked on the phone
  note          text,                                   -- the tech's explanation
  method        text check (method in ('office_code','owner')),
  approved_by   uuid references profiles(id)
);
create index on closeout_overrides (visit_id);
alter table closeout_overrides enable row level security;
revoke all on closeout_overrides from anon, authenticated;
grant select on closeout_overrides to authenticated;
-- Codes are for the contractor's office only; the store sees the outcome through the flag and summary.
create policy read_overrides on closeout_overrides for select using (exists (
  select 1 from work_orders w where w.id = work_order_id and is_contractor_office(w.contractor_id)));

-- Office: issue a one-time code for a tech who is on site and can't finish the normal way.
create or replace function issue_closeout_code(p_visit uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as $$
declare v visits; w work_orders; c text;
begin
  select * into v from visits where id = p_visit;
  select * into w from work_orders where id = v.work_order_id;
  if w.id is null or not is_contractor_office(w.contractor_id) then raise exception 'Only the contractor office can issue an override code.'; end if;
  if v.status <> 'on_site' then raise exception 'The technician must be on site.'; end if;
  if coalesce(length(trim(p_reason)), 0) < 5 then raise exception 'Note what the technician told you.'; end if;
  c := lpad((floor(random() * 1000000))::int::text, 6, '0');
  insert into closeout_overrides (visit_id, work_order_id, code, office_reason, issued_by, issued_at)
  values (v.id, w.id, c, trim(p_reason), auth.uid(), now());
  perform _notify(v.technician_id, w.id, 'guardrail_flag', format('Job #%s: close-out override code %s from %s.', w.number, c,
    (select full_name from profiles where id = auth.uid())), 'override:' || v.id || ':' || c);
  return c;
end $$;

-- Tech: close out with an override.
create or replace function tech_closeout_override(p_visit uuid, p_reason text, p_note text, p_code text default null,
  p_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders;
        o closeout_overrides; missing jsonb; who text; method text;
begin
  if v.status = 'done' then return jsonb_build_object('ok', true, 'already', true); end if;
  perform _on_site(v);
  if coalesce(trim(p_reason), '') = '' or coalesce(length(trim(p_note)), 0) < 10 then
    raise exception 'Pick a reason and explain what happened (at least a sentence).';
  end if;
  select * into w from work_orders where id = v.work_order_id;
  if nullif(trim(p_code), '') is not null then
    select * into o from closeout_overrides where visit_id = v.id and code = trim(p_code) and used_at is null
     order by issued_at desc limit 1 for update;
    if o.id is null then raise exception 'That override code is not right for this job. Check it with the office.'; end if;
    method := 'office_code';
    update closeout_overrides set used_at = now(), reason = trim(p_reason), note = trim(p_note), method = 'office_code', approved_by = issued_by
     where id = o.id;
    who := (select full_name from profiles where id = o.issued_by) || ' (office, by phone)';
  elsif m.is_org_admin and m.contractor_id = w.contractor_id then
    method := 'owner';
    insert into closeout_overrides (visit_id, work_order_id, reason, note, method, approved_by, used_at)
    values (v.id, w.id, trim(p_reason), trim(p_note), 'owner', m.id, now());
    who := m.full_name || ' (owner)';
  else
    raise exception 'Call your office for an override code.';
  end if;

  -- Money rules still apply.
  t := greatest(t, v.arrived_at);
  select jsonb_agg(jsonb_build_object('item', item, 'message', message)) into missing
    from completion_check(w.id, t) where item in ('approval_pending', 'po_cap', 'parts_open');
  if missing is not null then
    raise exception 'Still needed even with an override: %', (select string_agg(x->>'message', ' ') from jsonb_array_elements(missing) x);
  end if;

  update visits set status = 'done', outcome = 'completed', completed_at = t,
         outcome_note = format('Closed out by override (%s): %s', trim(p_reason), trim(p_note)) where id = v.id;
  w := _complete_job(w.id, t);
  perform _allow_internal();
  update work_orders set work_summary = coalesce(work_summary || ' ', '') ||
         format('Closed out without full documentation — %s: %s Approved by %s.', trim(p_reason), trim(p_note), who)
   where id = w.id returning * into w;
  perform _end_internal();
  perform _raise_flag(w.id, 'closeout_override', format('Closed without full documentation — %s: %s (approved by %s)',
    trim(p_reason), trim(p_note), who), false, true);
  perform _notify_customer(w.id, 'completed', format('Call #%s was closed out without the usual photos/details — %s: %s (approved by %s).',
    w.number, trim(p_reason), trim(p_note), who), 'override_done:' || v.id);
  return jsonb_build_object('ok', true, 'status', w.status, 'method', method, 'total_cost', w.total_cost);
end $$;

grant execute on function issue_closeout_code(uuid, text) to authenticated;
grant execute on function tech_closeout_override(uuid, text, text, text, timestamptz) to authenticated;
