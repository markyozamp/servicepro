-- Contractor side: every customer account the contractor serves, its stores (only the ones they serve), terms, totals,
-- and what needs attention at each store (drives the blinking pin, customer menu, tab badge and Customers tab).

create or replace function _contractor_serves_site(p_contractor uuid, p_site uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from sites s join customer_contractors cc on cc.customer_id = s.customer_id and cc.contractor_id = p_contractor
                 where s.id = p_site and (
                   exists (select 1 from trade_contractors tc where tc.customer_id = s.customer_id and tc.contractor_id = p_contractor
                           and (tc.site_id is null or tc.site_id = s.id))
                   or not exists (select 1 from trade_contractors tc where tc.customer_id = s.customer_id and tc.contractor_id = p_contractor)))
      or exists (select 1 from work_orders w where w.site_id = p_site and w.contractor_id = p_contractor)
$$;

create or replace function _contractor_site_reasons(p_contractor uuid, p_site uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select array_remove(array[
    case when exists (select 1 from work_orders w where w.site_id = p_site and w.contractor_id = p_contractor and w.status = 'created'
           and w.mode = 'verify' and w.accepted_at is null and w.declined_at is null and coalesce(w.accept_due_at, now() + interval '1 minute') >= now())
         then 'New call: not accepted yet' end,
    case when exists (select 1 from work_orders w where w.site_id = p_site and w.contractor_id = p_contractor and w.status = 'created'
           and w.mode = 'verify' and w.accepted_at is null and w.declined_at is null and w.accept_due_at < now())
         then 'Missed the accept deadline' end,
    case when exists (select 1 from work_orders w where w.site_id = p_site and w.contractor_id = p_contractor and w.status = 'created'
           and w.mode = 'verify' and w.accepted_at is not null and w.declined_at is null
           and not exists (select 1 from visits v where v.work_order_id = w.id and v.status <> 'cancelled'))
         then 'Accepted, no trip scheduled' end,
    case when exists (select 1 from visits v join work_orders w on w.id = v.work_order_id where w.site_id = p_site and w.contractor_id = p_contractor
           and v.status = 'assigned' and v.missed_alert_at is not null) then 'A visit missed its window' end,
    case when exists (select 1 from work_orders w where w.site_id = p_site and w.contractor_id = p_contractor and w.kind = 'pm'
           and w.due_on < current_date and w.status not in ('completed', 'invoiced', 'cancelled')) then 'Maintenance overdue' end,
    case when exists (select 1 from work_orders w where w.site_id = p_site and w.contractor_id = p_contractor and w.status = 'completed'
           and w.invoice_due_at < now()) then 'Bill not sent: past due' end,
    case when exists (select 1 from call_invoices ci join work_orders w on w.id = ci.work_order_id where w.site_id = p_site
           and w.contractor_id = p_contractor and ci.status = 'disputed') then 'Store disputed a bill' end,
    case when exists (select 1 from guardrail_flags g join work_orders w on w.id = g.work_order_id where w.site_id = p_site
           and w.contractor_id = p_contractor and g.resolved_at is null and g.blocking) then 'Call flagged for review' end
  ], null)
$$;

create or replace function contractor_book() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); y0 timestamptz := date_trunc('year', now());
begin
  if m.id is null or not m.active or m.contractor_id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object(
        'customer_id', c.id, 'name', c.name, 'kind', c.kind, 'phone', c.phone, 'email', c.email,
        'terms', jsonb_build_object('mode', cc.mode, 'pays_travel', cc.pays_travel, 'unverified_time', cc.unverified_time,
                   'accept_emergency_min', cc.accept_emergency_min, 'accept_normal_min', cc.accept_normal_min,
                   'min_hours', cc.min_hours, 'increment_min', cc.increment_min, 'terms_accepted_at', cc.terms_accepted_at, 'since', cc.created_at),
        'trades', (select coalesce(jsonb_agg(distinct t.name), '[]'::jsonb) from trade_contractors tc join trades t on t.id = tc.trade_id
                   where tc.customer_id = c.id and tc.contractor_id = m.contractor_id),
        'open_calls', (select count(*) from work_orders w where w.customer_id = c.id and w.contractor_id = m.contractor_id
                       and w.status not in ('completed', 'invoiced', 'cancelled') and w.declined_at is null),
        'to_bill', (select count(*) from work_orders w where w.customer_id = c.id and w.contractor_id = m.contractor_id and w.status = 'completed'),
        'calls_ytd', (select count(*) from work_orders w where w.customer_id = c.id and w.contractor_id = m.contractor_id and w.created_at >= y0),
        'billed_ytd', (select coalesce(sum(coalesce(ci.total, case when w.mode = 'full' then w.total_cost end, 0)), 0)
                       from work_orders w left join call_invoices ci on ci.work_order_id = w.id
                       where w.customer_id = c.id and w.contractor_id = m.contractor_id and w.status = 'invoiced' and w.created_at >= y0),
        'sites', (select coalesce(jsonb_agg(jsonb_build_object(
                    'site_id', s.id, 'name', s.name, 'address', s.address, 'timezone', s.timezone, 'access_notes', s.access_notes,
                    'require_checkin', s.require_checkin, 'has_backup_code', s.backup_code_hash is not null,
                    'open_calls', (select count(*) from work_orders w where w.site_id = s.id and w.contractor_id = m.contractor_id
                                   and w.status not in ('completed', 'invoiced', 'cancelled') and w.declined_at is null),
                    'reasons', to_jsonb(_contractor_site_reasons(m.contractor_id, s.id))) order by s.name), '[]'::jsonb)
                  from sites s where s.customer_id = c.id and _contractor_serves_site(m.contractor_id, s.id))
      ) as x
      from customer_contractors cc join customers c on c.id = cc.customer_id
      where cc.contractor_id = m.contractor_id
    ) t), '[]'::jsonb);
end $$;

-- One customer's equipment at the stores this contractor serves (for the customer page).
create or replace function contractor_customer_equipment(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.id is null or not m.active or m.contractor_id is null
     or not exists (select 1 from customer_contractors where customer_id = p_customer and contractor_id = m.contractor_id) then
    raise exception 'This customer isn''t on your list.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'site_id', e.site_id, 'site', s.name, 'type', et.name,
            'make', e.manufacturer, 'model', e.model, 'serial', e.serial, 'where', e.location_description, 'refrigerant', e.refrigerant,
            'installed', e.install_date) order by s.name, et.name, e.location_description)
    from equipment e join sites s on s.id = e.site_id left join equipment_types et on et.id = e.equipment_type_id
    where e.customer_id = p_customer and e.retired_at is null and _contractor_serves_site(m.contractor_id, e.site_id)), '[]'::jsonb);
end $$;

revoke execute on function _contractor_serves_site(uuid, uuid), _contractor_site_reasons(uuid, uuid) from public, anon, authenticated;
revoke execute on function contractor_book(), contractor_customer_equipment(uuid) from public, anon;
grant execute on function contractor_book(), contractor_customer_equipment(uuid) to authenticated;
