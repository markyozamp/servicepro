-- 1) Rate cards: what each contractor charges THIS customer (often not their street rate). Reference only:
--    nothing here changes the bill check. Every change is kept with its start date, so "what happened to our
--    labor rate?" has an answer. The store enters rates (accepted at once) or the contractor proposes them
--    (the store accepts or declines).
-- 2) Editing a contractor: the store's own contact for them + a note, always; the company name, office phone
--    and sign-in link only until the contractor has signed in (after that the company profile is theirs).
-- 3) Compare contractors: each contractor's current rates side by side, plus prospects' quotes the store types in.

create table if not exists contractor_rates (
  id             uuid primary key default gen_random_uuid(),
  customer_id    uuid not null references customers(id) on delete cascade,
  contractor_id  uuid not null references contractors(id) on delete cascade,
  effective_from date not null default current_date,
  rates          jsonb not null,
  status         text not null check (status in ('proposed','accepted','declined','replaced')),
  side           text not null check (side in ('store','contractor')),
  note           text,
  entered_by     uuid references profiles(id),
  entered_at     timestamptz not null default now(),
  decided_by     uuid references profiles(id),
  decided_at     timestamptz
);
create index if not exists contractor_rates_pair on contractor_rates (customer_id, contractor_id, effective_from desc);
alter table contractor_rates enable row level security;     -- read through rate_card() / compare_contractors()

create table if not exists rate_prospects (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references customers(id) on delete cascade,
  name         text not null,
  trade_ids    smallint[] not null default '{}',
  rates        jsonb not null,
  note         text,
  entered_by   uuid references profiles(id),
  entered_at   timestamptz not null default now(),
  archived_at  timestamptz
);
alter table rate_prospects enable row level security;

alter table customer_contractors add column if not exists contact_name  text,
                                 add column if not exists contact_phone text,
                                 add column if not exists contact_email text,
                                 add column if not exists store_note    text;

-- Clean and check a rate card: {regular, after_hours, helper, trip, markup_pct, custom:[{name, amount, unit}]}
create or replace function _clean_rates(p jsonb) returns jsonb
language plpgsql immutable as $$
declare out jsonb := '{}'; k text; v numeric; lim numeric; c jsonb; custom jsonb := '[]'; nm text; u text;
begin
  foreach k in array array['regular','after_hours','helper','trip','markup_pct'] loop
    if p ? k and nullif(p->>k, '') is not null then
      begin v := (p->>k)::numeric; exception when others then raise exception 'Use numbers for rates.'; end;
      lim := case when k = 'markup_pct' then 500 else 10000 end;
      if v < 0 or v > lim then raise exception 'That rate doesn''t look right: %.', v; end if;
      out := out || jsonb_build_object(k, round(v, 2));
    end if;
  end loop;
  if jsonb_typeof(p->'custom') = 'array' then
    if jsonb_array_length(p->'custom') > 4 then raise exception 'Up to 4 other rates.'; end if;
    for c in select * from jsonb_array_elements(p->'custom') loop
      nm := trim(coalesce(c->>'name', ''));
      if nm = '' and nullif(c->>'amount', '') is null then continue; end if;
      if length(nm) < 2 or length(nm) > 40 then raise exception 'Give each other rate a short name.'; end if;
      begin v := (c->>'amount')::numeric; exception when others then raise exception 'Use a number for %.', nm; end;
      if v is null or v < 0 or v > 10000 then raise exception 'That rate doesn''t look right: %.', nm; end if;
      u := coalesce(nullif(c->>'unit', ''), 'hr');
      if u not in ('hr','each','trip','pct') then u := 'each'; end if;
      custom := custom || jsonb_build_object('name', nm, 'amount', round(v, 2), 'unit', u);
    end loop;
  end if;
  if jsonb_array_length(custom) > 0 then out := out || jsonb_build_object('custom', custom); end if;
  if out = '{}' then raise exception 'Enter at least one rate.'; end if;
  return out;
end $$;

-- Who may look at a customer↔contractor rate card
create or replace function _rate_side(p_customer uuid, p_contractor uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when is_customer_member(p_customer) then 'store'
              when is_contractor_office(p_contractor) and exists (select 1 from customer_contractors cc
                     where cc.customer_id = p_customer and cc.contractor_id = p_contractor) then 'contractor' end
$$;

-- The card as of a date: current rates, what they replaced, a pending proposal, and the history
create or replace function rate_card(p_customer uuid, p_contractor uuid, p_at date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare side text := _rate_side(p_customer, p_contractor); cur contractor_rates; prev contractor_rates; pend contractor_rates; d date := coalesce(p_at, current_date);
begin
  if side is null then raise exception 'Not allowed.'; end if;
  select * into cur from contractor_rates where customer_id = p_customer and contractor_id = p_contractor and status = 'accepted'
     and effective_from <= d order by effective_from desc, decided_at desc limit 1;
  if cur.id is not null then
    select * into prev from contractor_rates where customer_id = p_customer and contractor_id = p_contractor and status = 'accepted'
       and (effective_from, decided_at) < (cur.effective_from, cur.decided_at) order by effective_from desc, decided_at desc limit 1;
  end if;
  select * into pend from contractor_rates where customer_id = p_customer and contractor_id = p_contractor and status = 'proposed'
   order by entered_at desc limit 1;
  return jsonb_build_object('side', side, 'as_of', d,
    'contractor', (select name from contractors where id = p_contractor),
    'customer', (select name from customers where id = p_customer),
    'current', case when cur.id is null then null else jsonb_build_object('id', cur.id, 'rates', cur.rates, 'from', cur.effective_from,
        'side', cur.side, 'by', (select full_name from profiles where id = cur.entered_by), 'accepted_at', cur.decided_at) end,
    'previous', case when prev.id is null then null else jsonb_build_object('rates', prev.rates, 'from', prev.effective_from) end,
    'pending', case when pend.id is null then null else jsonb_build_object('id', pend.id, 'rates', pend.rates, 'from', pend.effective_from,
        'note', pend.note, 'by', (select full_name from profiles where id = pend.entered_by), 'at', pend.entered_at) end,
    'scheduled', (select jsonb_build_object('rates', s.rates, 'from', s.effective_from) from contractor_rates s
        where s.customer_id = p_customer and s.contractor_id = p_contractor and s.status = 'accepted' and s.effective_from > d
        order by s.effective_from limit 1),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('rates', h.rates, 'from', h.effective_from, 'side', h.side,
        'by', (select full_name from profiles where id = h.entered_by), 'decided', h.decided_at) order by h.effective_from desc, h.decided_at desc), '[]')
        from contractor_rates h where h.customer_id = p_customer and h.contractor_id = p_contractor and h.status = 'accepted'));
end $$;
grant execute on function rate_card(uuid, uuid, date) to authenticated;

-- Store enters rates (in force at once) or the contractor proposes them (the store decides)
create or replace function save_rates(p_customer uuid, p_contractor uuid, p_rates jsonb, p_from date default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); side text := _rate_side(p_customer, p_contractor); r jsonb := _clean_rates(p_rates); d date := coalesce(p_from, current_date);
  newid uuid; cname text; kname text;
begin
  if side is null then raise exception 'Not allowed.'; end if;
  if side = 'store' and not store_can(p_customer, 'contractors') then raise exception 'You don''t have permission to change contractor rates.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if d < current_date - 365 or d > current_date + 365 then raise exception 'Pick a start date within a year of today.'; end if;
  select name into cname from customers where id = p_customer;
  select name into kname from contractors where id = p_contractor;
  -- a new entry replaces any proposal still waiting
  update contractor_rates set status = 'replaced', decided_at = now(), decided_by = m.id
   where customer_id = p_customer and contractor_id = p_contractor and status = 'proposed';
  insert into contractor_rates (customer_id, contractor_id, effective_from, rates, status, side, note, entered_by, decided_by, decided_at)
  values (p_customer, p_contractor, d, r, case when side = 'store' then 'accepted' else 'proposed' end, side, nullif(trim(p_note), ''), m.id,
          case when side = 'store' then m.id end, case when side = 'store' then now() end)
  returning id into newid;
  if side = 'contractor' then
    perform _notify(p.id, null, 'approval_request', format('%s entered their rates for %s, from %s. Review and accept them under Contractors → %s → Rates.',
        kname, cname, to_char(d, 'Mon DD, YYYY'), kname))
      from profiles p where p.customer_id = p_customer and p.active and (p.is_org_admin or p.can_manage_contractors);
  else
    perform _notify(p.id, null, 'approval_granted', format('%s updated the rates on record for you, from %s. See them on %s''s page.', cname, to_char(d, 'Mon DD, YYYY'), cname))
      from profiles p where p.contractor_id = p_contractor and p.active and (p.is_org_admin or p.can_dispatch);
  end if;
  return rate_card(p_customer, p_contractor);
end $$;
revoke execute on function save_rates(uuid, uuid, jsonb, date, text) from public, anon;
grant execute on function save_rates(uuid, uuid, jsonb, date, text) to authenticated;

create or replace function decide_rates(p_id uuid, p_accept boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); r contractor_rates; cname text;
begin
  select * into r from contractor_rates where id = p_id for update;
  if r.id is null or r.status <> 'proposed' then raise exception 'That proposal is no longer waiting.'; end if;
  if not store_can(r.customer_id, 'contractors') then raise exception 'You don''t have permission to change contractor rates.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if not p_accept and coalesce(length(trim(p_note)), 0) < 3 then raise exception 'Say why, so the contractor knows.'; end if;
  update contractor_rates set status = case when p_accept then 'accepted' else 'declined' end, decided_by = m.id, decided_at = now(),
         note = coalesce(nullif(trim(p_note), ''), note) where id = p_id;
  select name into cname from customers where id = r.customer_id;
  perform _notify(p.id, null, case when p_accept then 'approval_granted' else 'approval_declined' end::notify_type,
      case when p_accept then format('%s accepted your rates, from %s.', cname, to_char(r.effective_from, 'Mon DD, YYYY'))
           else format('%s didn''t accept your proposed rates: %s', cname, trim(p_note)) end)
    from profiles p where p.contractor_id = r.contractor_id and p.active and (p.is_org_admin or p.can_dispatch);
  return rate_card(r.customer_id, r.contractor_id);
end $$;
revoke execute on function decide_rates(uuid, boolean, text) from public, anon;
grant execute on function decide_rates(uuid, boolean, text) to authenticated;

-- Store: every contractor's current rates side by side (optionally one trade), plus prospects' quotes
create or replace function compare_contractors(p_trade smallint default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null then raise exception 'Not allowed.'; end if;
  return jsonb_build_object(
    'contractors', (select coalesce(jsonb_agg(x order by x->>'name'), '[]') from (
      select jsonb_build_object('contractor_id', cc.contractor_id, 'name', k.name,
        'trades', (select coalesce(jsonb_agg(distinct t.name), '[]') from trade_contractors tc join trades t on t.id = tc.trade_id
                    where tc.contractor_id = cc.contractor_id and tc.customer_id = m.customer_id),
        'card', (rate_card(m.customer_id, cc.contractor_id)->'current'),
        'previous', (rate_card(m.customer_id, cc.contractor_id)->'previous'),
        'pending', (rate_card(m.customer_id, cc.contractor_id)->'pending') is not null,
        'min_hours', cc.min_hours, 'increment_min', cc.increment_min, 'pays_travel', cc.pays_travel, 'is_primary', cc.is_primary) x
      from customer_contractors cc join contractors k on k.id = cc.contractor_id
      where cc.customer_id = m.customer_id and cc.store_removed_at is null
        and (p_trade is null or exists (select 1 from trade_contractors tc where tc.customer_id = m.customer_id
               and tc.contractor_id = cc.contractor_id and tc.trade_id = p_trade))) q),
    'prospects', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'rates', p.rates, 'note', p.note,
        'trades', (select coalesce(jsonb_agg(t.name), '[]') from trades t where t.id = any(p.trade_ids)), 'at', p.entered_at) order by p.entered_at desc), '[]')
      from rate_prospects p where p.customer_id = m.customer_id and p.archived_at is null
        and (p_trade is null or p_trade = any(p.trade_ids) or cardinality(p.trade_ids) = 0)));
end $$;
grant execute on function compare_contractors(smallint) to authenticated;

create or replace function save_prospect(p_id uuid, p_name text, p_rates jsonb, p_trade_ids smallint[] default '{}', p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); r jsonb := _clean_rates(p_rates); nid uuid;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to manage contractors.'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter the company''s name.'; end if;
  if p_id is null then
    insert into rate_prospects (customer_id, name, rates, trade_ids, note, entered_by)
    values (m.customer_id, trim(p_name), r, coalesce(p_trade_ids, '{}'), nullif(trim(p_note), ''), m.id) returning id into nid;
  else
    update rate_prospects set name = trim(p_name), rates = r, trade_ids = coalesce(p_trade_ids, '{}'), note = nullif(trim(p_note), '')
     where id = p_id and customer_id = m.customer_id returning id into nid;
    if nid is null then raise exception 'Not found.'; end if;
  end if;
  return jsonb_build_object('ok', true, 'id', nid);
end $$;
revoke execute on function save_prospect(uuid, text, jsonb, smallint[], text) from public, anon;
grant execute on function save_prospect(uuid, text, jsonb, smallint[], text) to authenticated;

create or replace function archive_prospect(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to manage contractors.'; end if;
  update rate_prospects set archived_at = now() where id = p_id and customer_id = m.customer_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function archive_prospect(uuid) from public, anon;
grant execute on function archive_prospect(uuid) to authenticated;

-- ---------- Editing a contractor (store side) ----------
-- Has anyone from the contractor signed in yet? Until then the store that invited them can fix their details.
create or replace function _contractor_signed_in(p_contractor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where contractor_id = p_contractor)
$$;

create or replace function contractor_details(p_contractor uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors; k contractors; l join_links;
begin
  if m.customer_id is null then raise exception 'Not allowed.'; end if;
  select * into cc from customer_contractors where customer_id = m.customer_id and contractor_id = p_contractor;
  if cc.contractor_id is null then raise exception 'Not your contractor.'; end if;
  select * into k from contractors where id = p_contractor;
  select * into l from join_links where contractor_id = p_contractor and kind = 'contractor_owner' and customer_id = m.customer_id
   order by created_at desc limit 1;
  return jsonb_build_object('name', k.name, 'office_phone', k.phone, 'email', k.email,
    'signed_in', _contractor_signed_in(p_contractor),
    'can_edit_company', not _contractor_signed_in(p_contractor) and l.token is not null,
    'invite', case when l.token is null then null else jsonb_build_object('name', l.full_name, 'email', l.email, 'phone', l.phone,
        'used', l.used_at is not null, 'expires_at', l.expires_at, 'expired', l.expires_at < now()) end,
    'contact_name', cc.contact_name, 'contact_phone', cc.contact_phone, 'contact_email', cc.contact_email, 'note', cc.store_note);
end $$;
grant execute on function contractor_details(uuid) to authenticated;

create or replace function store_update_contractor(p_contractor uuid, p_contact_name text, p_contact_phone text, p_contact_email text,
  p_note text, p_company text default null, p_office_phone text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); d jsonb;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to manage contractors.'; end if;
  if not exists (select 1 from customer_contractors where customer_id = m.customer_id and contractor_id = p_contractor) then raise exception 'Not your contractor.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if nullif(trim(p_contact_email), '') is not null and trim(p_contact_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address.'; end if;
  update customer_contractors set contact_name = nullif(trim(p_contact_name), ''), contact_phone = nullif(trim(p_contact_phone), ''),
         contact_email = nullif(lower(trim(p_contact_email)), ''), store_note = nullif(trim(p_note), '')
   where customer_id = m.customer_id and contractor_id = p_contractor;
  d := contractor_details(p_contractor);
  if (p_company is not null or p_office_phone is not null) then
    if not (d->>'can_edit_company')::boolean then
      raise exception 'They''ve signed in, so their company name and office phone are theirs to change.';
    end if;
    if p_company is not null and length(trim(p_company)) < 2 then raise exception 'Enter the company name.'; end if;
    perform _allow_internal(true);
    update contractors set name = coalesce(nullif(trim(p_company), ''), name), phone = coalesce(nullif(trim(p_office_phone), ''), phone)
     where id = p_contractor;
    perform _end_internal();
  end if;
  return contractor_details(p_contractor);
end $$;
revoke execute on function store_update_contractor(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function store_update_contractor(uuid, text, text, text, text, text, text) to authenticated;

-- Before they sign in: fix who the link goes to and make a fresh one (the old link stops working)
create or replace function store_new_contractor_link(p_contractor uuid, p_name text, p_email text, p_phone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); old join_links; tok uuid;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to manage contractors.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if _contractor_signed_in(p_contractor) then raise exception 'They''ve already signed in. They add their own people from their Team page.'; end if;
  select * into old from join_links where contractor_id = p_contractor and kind = 'contractor_owner' and customer_id = m.customer_id
   order by created_at desc limit 1;
  if old.token is null then raise exception 'Not your contractor.'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter the person''s name.'; end if;
  if nullif(trim(p_email), '') is null and nullif(trim(p_phone), '') is null then raise exception 'Enter an email or a mobile number.'; end if;
  update join_links set expires_at = least(expires_at, now()) where contractor_id = p_contractor and kind = 'contractor_owner' and used_at is null;
  insert into join_links (kind, contractor_id, customer_id, full_name, phone, email, created_by, perms)
  values ('contractor_owner', p_contractor, m.customer_id, trim(p_name), nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''), m.id, old.perms)
  returning token into tok;
  perform _allow_internal(true);
  update contractors set email = coalesce(nullif(lower(trim(p_email)), ''), email) where id = p_contractor;
  perform _end_internal();
  return jsonb_build_object('token', tok, 'name', trim(p_name), 'email', nullif(trim(p_email), ''), 'phone', nullif(trim(p_phone), ''));
end $$;
revoke execute on function store_new_contractor_link(uuid, text, text, text) from public, anon;
grant execute on function store_new_contractor_link(uuid, text, text, text) to authenticated;
