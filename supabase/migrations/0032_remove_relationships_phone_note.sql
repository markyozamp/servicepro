-- (1) A store can remove a contractor it no longer uses, and a contractor can remove a customer it no longer serves.
--     Past calls stay in both sides' records; the relationship just leaves the dashboards and no new calls can go to it. Restorable.
-- (2) Store notes "I talked to them" on a call (the phone call is the heads-up; the call record is the proof).
-- (3) Contractor sets its office phone (the number stores' "Call them now" / "Call office" buttons dial).

alter table customer_contractors
  add column if not exists store_removed_at timestamptz, add column if not exists store_removed_by uuid references profiles(id),
  add column if not exists contractor_removed_at timestamptz, add column if not exists contractor_removed_by uuid references profiles(id);

alter table work_orders
  add column if not exists store_phoned_at timestamptz, add column if not exists store_phone_note text,
  add column if not exists store_phoned_by_name text;

create or replace function _cc_open(p_customer uuid, p_contractor uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from work_orders where customer_id = p_customer and contractor_id = p_contractor
    and status not in ('invoiced', 'cancelled') and declined_at is null
$$;

-- No new or re-sent calls to a contractor that either side has removed.
create or replace function _wo_relationship_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare cc customer_contractors;
begin
  if new.contractor_id is null or (tg_op = 'UPDATE' and new.contractor_id is not distinct from old.contractor_id) then return new; end if;
  select * into cc from customer_contractors where customer_id = new.customer_id and contractor_id = new.contractor_id;
  if cc.store_removed_at is not null then raise exception 'That contractor was removed from your list. Restore them first.'; end if;
  if cc.contractor_removed_at is not null then raise exception 'That contractor no longer serves this customer.'; end if;
  return new;
end $$;
create or replace trigger wo_relationship_guard before insert or update of contractor_id on work_orders
  for each row execute function _wo_relationship_guard();

-- Default routing skips removed relationships.
create or replace function _route_contractor(p_site uuid, p_trade smallint) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select contractor_id from trade_contractors where site_id = p_site and trade_id = p_trade),
    (select tc.contractor_id from trade_contractors tc join sites s on s.customer_id = tc.customer_id
      where s.id = p_site and tc.site_id is null and tc.trade_id = p_trade),
    (select cc.contractor_id from customer_contractors cc join sites s on s.customer_id = cc.customer_id
      where s.id = p_site and cc.store_removed_at is null and cc.contractor_removed_at is null
      order by cc.is_primary desc, cc.created_at limit 1))
$$;

create or replace function _cc_unroute(p_customer uuid, p_contractor uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update trade_contractors set contractor_id = null, updated_at = now() where customer_id = p_customer and contractor_id = p_contractor;
  update pm_plans set active = false where customer_id = p_customer and contractor_id = p_contractor and active;
  update join_links set expires_at = now() where customer_id = p_customer and contractor_id = p_contractor and used_at is null and expires_at > now();
  if (select is_primary from customer_contractors where customer_id = p_customer and contractor_id = p_contractor) then
    update customer_contractors set is_primary = false where customer_id = p_customer and contractor_id = p_contractor;
    update customer_contractors set is_primary = true where customer_id = p_customer and contractor_id = (
      select contractor_id from customer_contractors where customer_id = p_customer and contractor_id <> p_contractor
        and store_removed_at is null and contractor_removed_at is null order by created_at limit 1);
  end if;
end $$;

-- Store: remove / restore a contractor
create or replace function remove_contractor(p_contractor uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors; n int; nm text;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to remove contractors.'; end if;
  cc := _cc(m.customer_id, p_contractor);
  if cc.contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  select name into nm from contractors where id = p_contractor;
  n := _cc_open(m.customer_id, p_contractor);
  if n > 0 then raise exception '% still has % open call%. Finish or cancel them first (a finished call is closed once it''s invoiced).', nm, n, case when n = 1 then '' else 's' end; end if;
  perform _cc_unroute(m.customer_id, p_contractor);
  update customer_contractors set store_removed_at = now(), store_removed_by = m.id where customer_id = m.customer_id and contractor_id = p_contractor;
  return jsonb_build_object('ok', true);
end $$;

create or replace function restore_contractor(p_contractor uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to change contractors.'; end if;
  cc := _cc(m.customer_id, p_contractor);
  if cc.contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  update customer_contractors set store_removed_at = null, store_removed_by = null where customer_id = m.customer_id and contractor_id = p_contractor;
  return jsonb_build_object('ok', true, 'contractor_ended', cc.contractor_removed_at is not null);
end $$;

-- Contractor: remove / restore a customer
create or replace function remove_customer(p_customer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors; n int; nm text;
begin
  if m.contractor_id is null or not m.active or not m.is_org_admin then raise exception 'Only your company admin can remove a customer.'; end if;
  cc := _cc(p_customer, m.contractor_id);
  if cc.contractor_id is null then raise exception 'This customer isn''t on your list.'; end if;
  select name into nm from customers where id = p_customer;
  n := _cc_open(p_customer, m.contractor_id);
  if n > 0 then raise exception 'You still have % open call% for %. Finish, invoice or cancel them first.', n, case when n = 1 then '' else 's' end, nm; end if;
  perform _cc_unroute(p_customer, m.contractor_id);
  update customer_contractors set contractor_removed_at = now(), contractor_removed_by = m.id where customer_id = p_customer and contractor_id = m.contractor_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function restore_customer(p_customer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors;
begin
  if m.contractor_id is null or not m.active or not m.is_org_admin then raise exception 'Only your company admin can restore a customer.'; end if;
  cc := _cc(p_customer, m.contractor_id);
  if cc.contractor_id is null then raise exception 'This customer isn''t on your list.'; end if;
  update customer_contractors set contractor_removed_at = null, contractor_removed_by = null where customer_id = p_customer and contractor_id = m.contractor_id;
  return jsonb_build_object('ok', true, 'store_ended', cc.store_removed_at is not null);
end $$;

create or replace function contractor_removed_customers() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('customer_id', c.id, 'name', c.name, 'removed_at', cc.contractor_removed_at) order by c.name), '[]'::jsonb)
  from customer_contractors cc join customers c on c.id = cc.customer_id join profiles me on me.id = auth.uid() and me.active and me.contractor_id = cc.contractor_id
  where cc.contractor_removed_at is not null
$$;

-- Store: "I talked to them"
create or replace function store_log_phone_contact(p_wo uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not (is_customer_member(w.customer_id) and can_see_site(w.site_id)) then raise exception 'Not allowed.'; end if;
  if coalesce(length(trim(p_note)), 0) < 3 then raise exception 'Say who you talked to (for example "Dana, 2:10 pm").'; end if;
  perform _allow_internal();
  update work_orders set store_phoned_at = now(), store_phone_note = left(trim(p_note), 300), store_phoned_by_name = m.full_name where id = w.id;
  perform _end_internal();
  return jsonb_build_object('ok', true);
end $$;

-- Contractor: office phone (dialed by the store's call buttons)
create or replace function set_contractor_office_phone(p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not m.active or not (m.is_org_admin or m.can_dispatch) then raise exception 'Only your office can change this.'; end if;
  if nullif(trim(p_phone), '') is not null and length(regexp_replace(p_phone, '\D', '', 'g')) < 10 then raise exception 'Enter a full phone number with area code.'; end if;
  update contractors set phone = nullif(trim(p_phone), '') where id = m.contractor_id;
  return jsonb_build_object('ok', true);
end $$;

-- The contractor's book leaves out customers the contractor removed and says when a store removed them.
create or replace function contractor_book() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); y0 timestamptz := date_trunc('year', now());
begin
  if m.id is null or not m.active or m.contractor_id is null then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object(
        'customer_id', c.id, 'name', c.name, 'kind', c.kind, 'phone', c.phone, 'email', c.email,
        'store_removed_at', cc.store_removed_at,
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
      where cc.contractor_id = m.contractor_id and cc.contractor_removed_at is null
    ) t), '[]'::jsonb);
end $$;

revoke execute on function _cc_open(uuid, uuid), _cc_unroute(uuid, uuid), _wo_relationship_guard() from public, anon, authenticated;
revoke execute on function remove_contractor(uuid), restore_contractor(uuid), remove_customer(uuid), restore_customer(uuid),
  contractor_removed_customers(), store_log_phone_contact(uuid, text), set_contractor_office_phone(text) from public, anon;
grant execute on function remove_contractor(uuid), restore_contractor(uuid), remove_customer(uuid), restore_customer(uuid),
  contractor_removed_customers(), store_log_phone_contact(uuid, text), set_contractor_office_phone(text) to authenticated;
