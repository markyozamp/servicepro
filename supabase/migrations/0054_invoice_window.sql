-- Each store chooses how many days its contractors have to send the invoice after the work is done
-- (per contractor). Order: a service agreement's own terms, then the store's choice, then the contractor's default, then 7.
alter table customer_contractors add column if not exists billing_days int check (billing_days between 1 and 90);

create or replace function _billing_days(p_wo uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(a.billing_days, cc.billing_days, c.billing_days, ps.default_billing_days)
  from work_orders w join contractors c on c.id = w.contractor_id cross join platform_settings ps
  left join agreements a on a.id = w.agreement_id
  left join customer_contractors cc on cc.customer_id = w.customer_id and cc.contractor_id = w.contractor_id
  where w.id = p_wo
$$;

create or replace function set_billing_days(p_contractor uuid, p_days int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to change contractor terms.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if p_days is not null and (p_days < 1 or p_days > 90) then raise exception 'Pick 1 to 90 days.'; end if;
  update customer_contractors set billing_days = p_days where customer_id = m.customer_id and contractor_id = p_contractor;
  if not found then raise exception 'Not your contractor.'; end if;
  return jsonb_build_object('ok', true, 'days', p_days);
end $$;
revoke execute on function set_billing_days(uuid, int) from public, anon;
grant execute on function set_billing_days(uuid, int) to authenticated;
