-- (1) What needs attention at each location the person can see (drives the blinking pin and the location menu).
-- (2) Anyone who can open calls can add a unit while opening a call.

create or replace function site_attention() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('site_id', s.id, 'name', s.name, 'reasons', array_remove(array[
      case when exists (select 1 from visits v join work_orders w on w.id = v.work_order_id where w.site_id = s.id and v.status = 'on_site'
             and v.checkin_required and v.checkin_at is null) then 'A technician is waiting for the check-in code' end,
      case when exists (select 1 from po_lines l join work_orders w on w.id = l.work_order_id where w.site_id = s.id and l.status = 'pending')
           then 'Waiting for your approval' end,
      case when exists (select 1 from work_orders w where w.site_id = s.id and w.status = 'completed' and w.invoice_due_at < now())
           then 'A bill is overdue' end,
      case when exists (select 1 from visits v join work_orders w on w.id = v.work_order_id where w.site_id = s.id and v.status = 'assigned'
             and v.missed_alert_at is not null) then 'A technician missed their window' end,
      case when exists (select 1 from site_visitors sv where sv.site_id = s.id and sv.recorded_at > now() - interval '24 hours')
           then 'Unscheduled visitor today' end,
      case when exists (select 1 from guardrail_flags g join work_orders w on w.id = g.work_order_id where w.site_id = s.id
             and g.resolved_at is null and g.visible_to_customer) then 'A call is flagged for review' end
    ], null)) as x
    from sites s join profiles me on me.id = auth.uid() and me.active and me.customer_id = s.customer_id
    where profile_sees_site(me.id, s.id)
  ) t
$$;
revoke execute on function site_attention() from public, anon;
grant execute on function site_attention() to authenticated;

create or replace function add_equipment_from_call(p_site uuid, p_type_code text, p_where text, p_make text, p_model text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites; m profiles := me(); tid uuid; e equipment;
begin
  select * into s from sites where id = p_site;
  if s.id is null or m.customer_id is distinct from s.customer_id or not profile_sees_site(m.id, s.id)
     or not (store_can(s.customer_id, 'calls') or store_can(s.customer_id, 'equipment')) then
    raise exception 'You can''t add equipment at this location.';
  end if;
  if nullif(trim(p_type_code), '') is not null then
    select id into tid from equipment_types where code = p_type_code and contractor_id is null;
  end if;
  if tid is null and nullif(trim(p_where), '') is null and nullif(trim(p_make), '') is null then
    raise exception 'Pick what kind of unit it is, or say where it is.';
  end if;
  insert into equipment (customer_id, site_id, equipment_type_id, manufacturer, model, location_description, created_by)
  values (s.customer_id, s.id, tid, nullif(trim(p_make), ''), nullif(trim(p_model), ''), nullif(trim(p_where), ''), m.id)
  returning * into e;
  perform _eq_log(e.id, 'added', concat_ws(' ', 'from a service call:', (select name from equipment_types where id = tid), e.manufacturer, e.model, e.location_description));
  return jsonb_build_object('ok', true, 'id', e.id);
end $$;
revoke execute on function add_equipment_from_call(uuid, text, text, text, text) from public, anon;
grant execute on function add_equipment_from_call(uuid, text, text, text, text) to authenticated;
