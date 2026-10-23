-- Contractor invite takes the office phone (used for "Call office"); the mobile stays on the sign-in link for texting.
-- PO log gains the trade so past calls can be filtered by Refrigeration, Plumbing, etc.
-- New 7-argument version (office phone required as the last argument, may be null); the 6-argument version stays for older callers.
create or replace function invite_contractor(p_company text, p_contact_name text, p_email text, p_phone text,
  p_trade_ids smallint[], p_site_ids uuid[], p_office_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cid uuid; tok uuid; tr smallint; st uuid;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to invite contractors.'; end if;
  if coalesce(length(trim(p_company)), 0) < 2 or coalesce(length(trim(p_contact_name)), 0) < 2 then
    raise exception 'Enter the company and the person''s name.';
  end if;
  if nullif(trim(p_email), '') is null and nullif(trim(p_phone), '') is null then raise exception 'Enter an email or a mobile number.'; end if;
  if p_site_ids is not null and exists (select 1 from unnest(p_site_ids) x where not exists (
       select 1 from sites s where s.id = x and s.customer_id = m.customer_id)) then raise exception 'Not your location.'; end if;
  insert into contractors (name, phone, email) values (trim(p_company), coalesce(nullif(trim(p_office_phone), ''), nullif(trim(p_phone), '')), nullif(lower(trim(p_email)), ''))
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
revoke execute on function invite_contractor(text, text, text, text, smallint[], uuid[], text) from public, anon;
grant execute on function invite_contractor(text, text, text, text, smallint[], uuid[], text) to authenticated;

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
             order by f.triggered_at) as flags,
       w.trade_id, tr.name as trade_name
from work_orders w
  join sites s on s.id = w.site_id
  join contractors c on c.id = w.contractor_id
  left join issue_types it on it.id = w.issue_type_id
  left join equipment e on e.id = w.equipment_id
  left join equipment_types et on et.id = e.equipment_type_id
  left join call_invoices ci on ci.work_order_id = w.id
  left join trades tr on tr.id = w.trade_id;
