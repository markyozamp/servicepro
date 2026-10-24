-- Base: bills to QuickBooks without retyping. The office downloads the bills the app wrote (in a date range, or only
-- the ones not downloaded yet) as a QuickBooks Online invoice import file, or a QuickBooks Desktop (.iif) file, plus
-- a customer list. Downloaded bills are marked, so nothing goes in twice. (Live sync comes with Pro.)

alter table call_invoices add column if not exists exported_at timestamptz;
alter table call_invoices add column if not exists exported_by uuid;

create or replace function invoice_export(p_from date default null, p_to date default null, p_only_new boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) or not is_contractor_office(m.contractor_id) then
    raise exception 'Only your owner or billing can export bills.';
  end if;
  if not _is_base(m.contractor_id) then raise exception 'Exporting to QuickBooks comes with Base.'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'work_order_id', w.id, 'invoice_number', i.invoice_number, 'date', (i.entered_at at time zone coalesce(c.timezone, 'America/Chicago'))::date,
      'customer', cu.name, 'customer_email', cu.email, 'customer_phone', cu.phone, 'contact', cu.contact_name,
      'site', s.name, 'address', s.address, 'call_number', w.number, 'po', i.po_number, 'total', i.total, 'lines', i.lines,
      'paid_at', i.paid_at, 'exported_at', i.exported_at) order by i.entered_at), '[]')
    from call_invoices i join work_orders w on w.id = i.work_order_id join customers cu on cu.id = w.customer_id
    join sites s on s.id = w.site_id join contractors c on c.id = w.contractor_id
    where w.contractor_id = m.contractor_id and i.built and i.entered_side = 'contractor'
      and (p_from is null or i.entered_at >= p_from) and (p_to is null or i.entered_at < p_to + 1)
      and (not coalesce(p_only_new, true) or i.exported_at is null));
end $$;

create or replace function mark_invoices_exported(p_work_orders uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); n int;
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) then raise exception 'Only your owner or billing can export bills.'; end if;
  update call_invoices i set exported_at = now(), exported_by = m.id
   from work_orders w where w.id = i.work_order_id and w.contractor_id = m.contractor_id and i.work_order_id = any(p_work_orders);
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function invoice_export(date, date, boolean), mark_invoices_exported(uuid[]) to authenticated;
