-- Demo only: there's no real technician at the store, so the store visitor taps "the tech types in the code"
-- and the check-in happens as if the tech had entered it on his phone.
create or replace function demo_tech_enters_code(p_visit uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); v visits; w work_orders;
begin
  if m.id is null or m.email not like '%.demo' then raise exception 'This button is only in the demo.'; end if;
  select * into v from visits where id = p_visit;
  select * into w from work_orders where id = v.work_order_id;
  if w.id is null or w.customer_id is distinct from m.customer_id or not can_see_site(w.site_id) then raise exception 'Not allowed.'; end if;
  if v.status <> 'on_site' or v.arrived_at is null then raise exception 'The technician isn''t on site.'; end if;
  if v.checkin_at is not null and v.checkin_verified then return jsonb_build_object('ok', true, 'already', true); end if;
  perform _allow_internal(true);
  update visits set checkin_at = now(), checkin_method = 'code', checkin_verified = true, checkin_person = null, checkin_reason = null where id = v.id;
  update guardrail_flags set resolved_at = now(), resolution_note = 'Verified with the right code'
   where work_order_id = w.id and flag = 'checkin_unverified' and resolved_at is null and description not like '%waited%';
  perform _end_internal();
  perform _notify_customer(w.id, 'checkin', format('Check-in confirmed for call #%s.', w.number));
  perform _notify_office(w.id, 'checkin', format('Call #%s: %s checked in with the store''s code.', w.number, (select full_name from profiles where id = v.technician_id)));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function demo_tech_enters_code(uuid) from public, anon;
grant execute on function demo_tech_enters_code(uuid) to authenticated;
