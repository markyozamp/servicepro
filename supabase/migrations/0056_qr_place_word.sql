-- The QR report page speaks the customer's word too ("Store PIN", "Restaurant PIN", "Location PIN").
create or replace function qr_info(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e equipment; s sites; et equipment_types;
begin
  select * into e from equipment where qr_token = p_token;
  if e.id is null then return jsonb_build_object('ok', false); end if;
  select * into s from sites where id = e.site_id;
  select * into et from equipment_types where id = e.equipment_type_id;
  return jsonb_build_object('ok', true, 'store', (select name from customers where id = s.customer_id), 'site', s.name,
    'place_word', (select place_word from customers where id = s.customer_id),
    'unit', concat_ws(' — ', et.name, e.location_description), 'has_pin', exists (select 1 from site_report_pins where site_id = s.id),
    'issues', (select coalesce(jsonb_agg(jsonb_build_object('id', it.id, 'name', it.name, 'priority', it.priority) order by it.priority, it.name), '[]')
               from issue_types it where it.active and (et.trade_id is null or it.trade_id = et.trade_id)
                 and (it.equipment_type_code is null or it.equipment_type_code = et.code)),
    'open_calls', (select coalesce(jsonb_agg(jsonb_build_object('number', w.number, 'status', w.status, 'problem', w.issue_description,
                     'opened', _local(w.created_at, w.site_id, 'Mon DD HH12:MI AM')) order by w.created_at desc), '[]')
                   from work_orders w where w.equipment_id = e.id and w.status not in ('completed','invoiced','cancelled')));
end $$;
