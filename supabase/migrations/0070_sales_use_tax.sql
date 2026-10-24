-- Base: sales tax and use tax, set up by the contractor (we never publish a rate).
--  * Tax rates: the contractor lists his own: one rate per state he works in (everywhere in that state not listed),
--    plus the cities / special districts with a different total rate. Each says whether labor and the trip charge
--    are taxed there, when he last checked it, and where he checks it.
--  * A location gets its rate automatically (its city on his list, else its state), or the office picks one.
--  * Each bill or quote line is Taxed (sales tax on the price, shown to the customer), Built-in (becomes part of the
--    building: no tax on the bill; he owes use tax on HIS cost of it), or No tax. Parts remember "built in".
--  * Tax-exempt customers (certificate on file): no sales tax on their bill; use tax on built-in parts is still owed.
--  * The bill and the quote show subtotal, sales tax and total; the contractor alone sees the use tax he owes.
--  * The monthly tax report: sales by rate (taxed, not taxed, exempt), sales tax charged, use tax owed on cost.
-- Costs never reach the customer: what the customer can read carries no cost, and the private numbers are in invoice_tax.

create table if not exists tax_areas (
  id            uuid primary key default gen_random_uuid(),
  contractor_id uuid not null references contractors(id) on delete cascade,
  name          text not null,                 -- as it's named in their QuickBooks
  state         text not null,                 -- two letters
  city          text,                          -- null = the state rate
  rate          numeric(7,4) not null check (rate >= 0 and rate < 30),   -- total percent
  labor_taxed   boolean not null default false,
  trip_taxed    boolean not null default false,
  lookup_url    text,
  checked_on    date,
  created_at    timestamptz not null default now(),
  removed_at    timestamptz
);
create index if not exists tax_areas_contractor on tax_areas (contractor_id) where removed_at is null;
alter table tax_areas enable row level security;

create table if not exists site_tax_areas (          -- the office picked a rate for this location
  contractor_id uuid not null references contractors(id) on delete cascade,
  site_id       uuid not null references sites(id) on delete cascade,
  tax_area_id   uuid references tax_areas(id),        -- null = automatic again
  updated_at    timestamptz not null default now(),
  primary key (contractor_id, site_id)
);
alter table site_tax_areas enable row level security;

create table if not exists invoice_tax (             -- the private side of a sent bill (cost, use tax)
  work_order_id uuid primary key references work_orders(id) on delete cascade,
  contractor_id uuid not null,
  tax_area_id   uuid,
  tax_area      text,
  state         text,
  rate          numeric(7,4),
  exempt        boolean not null default false,
  subtotal      numeric(12,2) not null default 0,
  taxable       numeric(12,2) not null default 0,     -- lines marked taxed
  nontaxable    numeric(12,2) not null default 0,     -- built-in and no-tax lines
  sales_tax     numeric(12,2) not null default 0,
  use_basis     numeric(12,2) not null default 0,     -- his cost of built-in parts
  use_tax       numeric(12,2) not null default 0,
  lines         jsonb not null default '[]',
  sent_at       timestamptz not null default now()
);
create index if not exists invoice_tax_contractor on invoice_tax (contractor_id, sent_at);
alter table invoice_tax enable row level security;

alter table contractors add column if not exists use_tax_paid_at_purchase boolean not null default false;
alter table customer_contractors add column if not exists tax_exempt boolean not null default false;
alter table customer_contractors add column if not exists tax_exempt_note text;
alter table customer_contractors add column if not exists tax_exempt_until date;
alter table parts add column if not exists built_in boolean;
alter table call_invoices add column if not exists subtotal numeric(12,2);
alter table call_invoices add column if not exists sales_tax numeric(12,2);
alter table call_invoices add column if not exists tax_rate numeric(7,4);
alter table call_invoices add column if not exists tax_area text;
alter table call_invoices add column if not exists tax_exempt boolean;
alter table quotes add column if not exists subtotal numeric(12,2);
alter table quotes add column if not exists sales_tax numeric(12,2);
alter table quotes add column if not exists tax_rate numeric(7,4);
alter table quotes add column if not exists tax_area text;
alter table quotes add column if not exists tax_exempt boolean;
alter table quotes add column if not exists use_tax numeric(12,2);

-- ---------- helpers ----------
create or replace function _addr_state(p_address text) returns text language sql immutable as $$
  select upper(coalesce(substring(p_address from ',\s*([A-Za-z]{2})\s+\d{5}'), substring(p_address from ',\s*([A-Za-z]{2})\s*$')))
$$;

-- The rate for this location: the one the office picked, else its city on the list, else its state.
create or replace function _tax_area_for(p_contractor uuid, p_site uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s sites; a tax_areas; st text; src text; addr text;
begin
  select * into s from sites where id = p_site;
  if s.id is null then return null; end if;
  select t.* into a from site_tax_areas x join tax_areas t on t.id = x.tax_area_id and t.removed_at is null
   where x.contractor_id = p_contractor and x.site_id = p_site;
  if a.id is not null then src := 'picked';
  else
    st := _addr_state(s.address);
    addr := ', ' || regexp_replace(lower(s.address), '\s*,\s*', ', ', 'g');
    select * into a from tax_areas t
     where t.contractor_id = p_contractor and t.removed_at is null and t.city is not null and (st is null or t.state = st)
       and position(', ' || lower(trim(t.city)) || ',' in addr) > 0
     order by length(t.city) desc limit 1;
    if a.id is not null then src := 'city';
    else
      select * into a from tax_areas t
       where t.contractor_id = p_contractor and t.removed_at is null and t.city is null
         and (t.state = st or (st is null and (select count(*) from tax_areas z where z.contractor_id = p_contractor and z.removed_at is null and z.city is null) = 1))
       order by t.created_at limit 1;
      if a.id is not null then src := 'state'; end if;
    end if;
  end if;
  if a.id is null then return null; end if;
  return jsonb_build_object('id', a.id, 'name', a.name, 'state', a.state, 'city', a.city, 'rate', a.rate,
    'labor', a.labor_taxed, 'trip', a.trip_taxed, 'source', src);
end $$;

create or replace function _line_tax_default(p_kind text, p_area jsonb, p_built_in boolean default null) returns text
language sql immutable as $$
  select case
    when p_kind in ('labor', 'after_hours', 'helper', 'flat') then case when coalesce((p_area->>'labor')::boolean, false) then 'sales' else 'none' end
    when p_kind = 'trip' then case when coalesce((p_area->>'trip')::boolean, false) then 'sales' else 'none' end
    when p_kind in ('part', 'equipment') and coalesce(p_built_in, false) then 'use'
    else 'sales' end
$$;

-- What the customer may read of the lines (no costs, no internal flags)
create or replace function _lines_public(p_lines jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(x - 'cost' - 'auto' - 'part_id' order by n), '[]') from jsonb_array_elements(coalesce(p_lines, '[]')) with ordinality as e(x, n)
$$;

-- The tax on a set of lines for this contractor, location and customer
create or replace function _tax_calc(p_contractor uuid, p_site uuid, p_customer uuid, p_lines jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a jsonb := _tax_area_for(p_contractor, p_site); cc customer_contractors; on_ boolean; ex boolean; rate numeric;
  sub numeric; taxable numeric; ub numeric; nocost int; stax numeric := 0; utax numeric := 0;
begin
  on_ := exists (select 1 from tax_areas where contractor_id = p_contractor and removed_at is null);
  select * into cc from customer_contractors where contractor_id = p_contractor and customer_id = p_customer;
  ex := coalesce(cc.tax_exempt, false) and (cc.tax_exempt_until is null or cc.tax_exempt_until >= current_date);
  rate := coalesce((a->>'rate')::numeric, 0);
  select coalesce(sum(amt), 0), coalesce(sum(amt) filter (where tx = 'sales'), 0),
         coalesce(sum(round(qty * cost, 2)) filter (where tx = 'use'), 0), count(*) filter (where tx = 'use' and cost is null)
    into sub, taxable, ub, nocost
    from (select coalesce((x->>'amount')::numeric, 0) amt, coalesce((x->>'qty')::numeric, 0) qty, nullif(x->>'cost', '')::numeric cost,
                 coalesce(nullif(x->>'tax', ''), _line_tax_default(x->>'kind', a, null)) tx
            from jsonb_array_elements(coalesce(p_lines, '[]')) x) y;
  if on_ and a is not null then
    if not ex then stax := round(taxable * rate / 100, 2); end if;
    utax := round(ub * rate / 100, 2);
  end if;
  return jsonb_build_object('on', on_, 'area', a, 'rate', case when a is not null then rate end, 'exempt', ex,
    'exempt_note', cc.tax_exempt_note, 'exempt_until', cc.tax_exempt_until,
    'missing', on_ and a is null and taxable > 0 and not ex,
    'subtotal', sub, 'taxable', taxable, 'nontaxable', sub - taxable, 'sales_tax', stax,
    'use_basis', ub, 'use_tax', utax, 'use_missing_cost', nocost, 'total', sub + stax,
    'paid_at_purchase', coalesce((select use_tax_paid_at_purchase from contractors where id = p_contractor), false));
end $$;

create or replace function _tax_office(p_billing boolean default false) returns profiles
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Not allowed.'; end if;
  if p_billing and not (m.is_org_admin or m.can_bill) then raise exception 'Only your owner or billing can change tax settings.'; end if;
  if not _is_base(m.contractor_id) then raise exception 'Sales tax on bills comes with Base.'; end if;
  return m;
end $$;

-- ---------- contractor: tax setup ----------
create or replace function tax_settings() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := _tax_office(false);
begin
  return jsonb_build_object(
    'paid_at_purchase', (select use_tax_paid_at_purchase from contractors where id = m.contractor_id),
    'can_edit', m.is_org_admin or m.can_bill,
    'quarter_start', date_trunc('quarter', current_date)::date,
    'stale', exists (select 1 from tax_areas where contractor_id = m.contractor_id and removed_at is null
                      and (checked_on is null or checked_on < date_trunc('quarter', current_date)::date)),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'state', t.state, 'city', t.city, 'rate', t.rate,
                'labor_taxed', t.labor_taxed, 'trip_taxed', t.trip_taxed, 'lookup_url', t.lookup_url, 'checked_on', t.checked_on)
                order by t.state, t.city nulls first, t.name), '[]')
              from tax_areas t where t.contractor_id = m.contractor_id and t.removed_at is null));
end $$;

create or replace function save_tax_area(p_id uuid, p_name text, p_state text, p_city text, p_rate numeric,
  p_labor boolean default false, p_trip boolean default false, p_lookup_url text default null, p_checked boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _tax_office(true); st text := upper(trim(p_state)); ct text := nullif(trim(p_city), ''); t tax_areas;
begin
  if st !~ '^[A-Z]{2}$' then raise exception 'Use the two-letter state, like ND.'; end if;
  if p_rate is null or p_rate < 0 or p_rate >= 30 then raise exception 'Enter the total rate as a percent, like 7.5.'; end if;
  if p_lookup_url is not null and trim(p_lookup_url) <> '' and trim(p_lookup_url) !~* '^https?://' then raise exception 'The lookup link should start with https://'; end if;
  if exists (select 1 from tax_areas where contractor_id = m.contractor_id and removed_at is null and id is distinct from p_id
             and state = st and lower(coalesce(city, '')) = lower(coalesce(ct, ''))) then
    raise exception '% is already on your list.', coalesce(ct || ', ', '') || st || case when ct is null then ' (state rate)' else '' end;
  end if;
  if p_id is null then
    insert into tax_areas (contractor_id, name, state, city, rate, labor_taxed, trip_taxed, lookup_url, checked_on)
    values (m.contractor_id, coalesce(nullif(trim(p_name), ''), coalesce(ct || ' ', '') || st), st, ct, p_rate, coalesce(p_labor, false),
            coalesce(p_trip, false), nullif(trim(p_lookup_url), ''), case when coalesce(p_checked, true) then current_date end)
    returning * into t;
  else
    update tax_areas set name = coalesce(nullif(trim(p_name), ''), name), state = st, city = ct, rate = p_rate, labor_taxed = coalesce(p_labor, false),
           trip_taxed = coalesce(p_trip, false), lookup_url = nullif(trim(p_lookup_url), ''),
           checked_on = case when coalesce(p_checked, true) then current_date else checked_on end
     where id = p_id and contractor_id = m.contractor_id and removed_at is null returning * into t;
    if t.id is null then raise exception 'That rate isn''t on your list.'; end if;
  end if;
  return to_jsonb(t);
end $$;

create or replace function remove_tax_area(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _tax_office(true);
begin
  update tax_areas set removed_at = now() where id = p_id and contractor_id = m.contractor_id and removed_at is null;
  update site_tax_areas set tax_area_id = null, updated_at = now() where contractor_id = m.contractor_id and tax_area_id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function mark_tax_rates_checked() returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _tax_office(true); n int;
begin
  update tax_areas set checked_on = current_date where contractor_id = m.contractor_id and removed_at is null;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'checked', n);
end $$;

create or replace function set_use_tax_paid_at_purchase(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _tax_office(true);
begin
  update contractors set use_tax_paid_at_purchase = coalesce(p_on, false) where id = m.contractor_id;
  return jsonb_build_object('ok', true);
end $$;

-- The tax for one location (bill and quote screens): its rate, why, the choices, and the customer's exemption
create or replace function site_tax(p_site uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := _tax_office(false); s sites; cc customer_contractors;
begin
  select * into s from sites where id = p_site;
  select * into cc from customer_contractors where contractor_id = m.contractor_id and customer_id = s.customer_id;
  if s.id is null or cc.contractor_id is null then raise exception 'That isn''t one of your customers.'; end if;
  return jsonb_build_object('site_id', s.id, 'customer_id', s.customer_id, 'address', s.address,
    'on', exists (select 1 from tax_areas where contractor_id = m.contractor_id and removed_at is null),
    'area', _tax_area_for(m.contractor_id, s.id),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'rate', t.rate) order by t.state, t.city nulls first, t.name), '[]')
              from tax_areas t where t.contractor_id = m.contractor_id and t.removed_at is null),
    'exempt', cc.tax_exempt, 'exempt_note', cc.tax_exempt_note, 'exempt_until', cc.tax_exempt_until,
    'can_exempt', m.is_org_admin or m.can_bill);
end $$;

create or replace function set_site_tax_area(p_site uuid, p_area uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _tax_office(false);
begin
  if not exists (select 1 from sites s join customer_contractors cc on cc.customer_id = s.customer_id and cc.contractor_id = m.contractor_id where s.id = p_site) then
    raise exception 'That isn''t one of your customers.';
  end if;
  if p_area is not null and not exists (select 1 from tax_areas where id = p_area and contractor_id = m.contractor_id and removed_at is null) then
    raise exception 'That rate isn''t on your list.';
  end if;
  insert into site_tax_areas (contractor_id, site_id, tax_area_id) values (m.contractor_id, p_site, p_area)
  on conflict (contractor_id, site_id) do update set tax_area_id = excluded.tax_area_id, updated_at = now();
  return site_tax(p_site);
end $$;

create or replace function set_customer_tax_exempt(p_customer uuid, p_exempt boolean, p_note text default null, p_until date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _tax_office(true); n int;
begin
  if coalesce(p_exempt, false) and coalesce(length(trim(p_note)), 0) < 3 then
    raise exception 'Note the exemption certificate (number or type) so it''s on file.';
  end if;
  update customer_contractors set tax_exempt = coalesce(p_exempt, false), tax_exempt_note = nullif(trim(p_note), ''), tax_exempt_until = p_until
   where contractor_id = m.contractor_id and customer_id = p_customer;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'That isn''t one of your customers.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- A part "becomes part of the building" (built in: use tax on cost), remembered for next time
create or replace function set_part_built_in(p_part uuid, p_built_in boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _tax_office(false); n int;
begin
  update parts set built_in = p_built_in where id = p_part and contractor_id = m.contractor_id;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0);
end $$;

-- ---------- the bill ----------
-- Lines from the record now carry their tax (and, private, the part's cost). A call that came from an approved quote
-- is billed as quoted.
create or replace function _bill_auto_lines(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; v jsonb := _verified(p_wo); r jsonb := _bill_rates(p_wo); tech numeric; ah numeric; helper numeric; trips int;
  out jsonb := '[]'; p record; a jsonb; ql jsonb;
begin
  select * into w from work_orders where id = p_wo;
  a := _tax_area_for(w.contractor_id, w.site_id);
  select q.lines into ql from quotes q where q.work_order_id = p_wo and q.status = 'approved' order by q.decided_at desc limit 1;
  if ql is not null and jsonb_array_length(ql) > 0 then
    return (select coalesce(jsonb_agg((x - 'auto') || jsonb_build_object('auto', true) order by n), '[]') from jsonb_array_elements(ql) with ordinality e(x, n));
  end if;
  tech := coalesce((v->>'tech_billable_h')::numeric, 0);
  ah := least(coalesce((v->>'after_hours_h')::numeric, 0), tech);
  helper := coalesce((v->>'helper_billable_h')::numeric, 0);
  trips := jsonb_array_length(coalesce(v->'visits', '[]'));
  if w.flat_amount > 0 then out := out || (_bill_line('flat', 'Preventive maintenance visit', 1, 'visit', w.flat_amount) || jsonb_build_object('tax', _line_tax_default('flat', a))); end if;
  if _is_flat(p_wo) then
    for p in select t.name, t.qty quantity, t.price from call_tasks t where t.work_order_id = p_wo and t.removed_at is null order by t.added_at loop
      out := out || (_bill_line('task', p.name, p.quantity, 'ea', p.price) || jsonb_build_object('tax', 'sales'));
    end loop;
    return out;
  end if;
  if tech - ah > 0 then out := out || (_bill_line('labor', 'Labor (verified on site)', tech - ah, 'hr', (r->>'regular')::numeric) || jsonb_build_object('tax', _line_tax_default('labor', a))); end if;
  if ah > 0 then out := out || (_bill_line('after_hours', 'Labor, after hours (verified on site)', ah, 'hr', (r->>'after_hours')::numeric) || jsonb_build_object('tax', _line_tax_default('labor', a))); end if;
  if helper > 0 then out := out || (_bill_line('helper', 'Helper labor (crew confirmed on site)', helper, 'hr', (r->>'helper')::numeric) || jsonb_build_object('tax', _line_tax_default('labor', a))); end if;
  if trips > 0 and coalesce((r->>'trip')::numeric, 0) > 0 then out := out || (_bill_line('trip', 'Trip charge', trips, 'trip', (r->>'trip')::numeric) || jsonb_build_object('tax', _line_tax_default('trip', a))); end if;
  for p in select pt.id part_id, pt.name, pt.built_in, pu.quantity, pu.unit_cost,
                  coalesce(pu.unit_price, round(pu.unit_cost * (1 + coalesce((r->>'markup_pct')::numeric, 0) / 100), 2)) price
             from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = p_wo and not coalesce(pu.covered, false)
             order by pu.added_at loop
    out := out || (_bill_line('part', p.name, p.quantity, 'ea', p.price)
                   || jsonb_strip_nulls(jsonb_build_object('tax', _line_tax_default('part', a, p.built_in), 'cost', p.unit_cost, 'part_id', p.part_id)));
  end loop;
  return out;
end $$;

create or replace function _clean_line_extras(x jsonb) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'tax', case when x->>'tax' in ('sales', 'use', 'none') then x->>'tax' end,
    'cost', case when nullif(x->>'cost', '') is null then null else greatest(0, (x->>'cost')::numeric) end,
    'part_id', case when x->>'part_id' ~ '^[0-9a-f-]{36}$' then x->>'part_id' end))
$$;

create or replace function save_bill(p_wo uuid, p_lines jsonb, p_invoice_number text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _bill_guard(p_wo); clean jsonb;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) > 60 then raise exception 'Up to 60 lines on a bill.'; end if;
  select coalesce(jsonb_agg(_bill_line(
           case when x->>'kind' in ('labor', 'after_hours', 'helper', 'trip', 'part', 'flat', 'task', 'equipment', 'other') then x->>'kind' else 'other' end,
           left(trim(x->>'description'), 200),
           greatest(0, coalesce(nullif(x->>'qty', '')::numeric, 0)),
           left(coalesce(x->>'unit', ''), 10),
           case when nullif(x->>'rate', '') is null then null else greatest(0, (x->>'rate')::numeric) end,
           coalesce((x->>'auto')::boolean, false)) || _clean_line_extras(x) order by n), '[]')
    into clean
    from jsonb_array_elements(p_lines) with ordinality e(x, n) where coalesce(trim(x->>'description'), '') <> '';
  perform bill_draft(p_wo);
  update bill_drafts set lines = clean, invoice_number = coalesce(nullif(trim(p_invoice_number), ''), invoice_number),
         note = nullif(trim(p_note), ''), updated_at = now(), updated_by = auth.uid()
   where work_order_id = p_wo;
  return _bill_summary(p_wo);
end $$;

-- The summary: 'total' is now what the customer pays (subtotal + sales tax); the limit is checked on the subtotal.
create or replace function _bill_summary(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d bill_drafts; w work_orders; v jsonb := _verified(p_wo); chk jsonb := _invoice_check(p_wo); labor numeric; missing boolean; t jsonb;
begin
  select * into d from bill_drafts where work_order_id = p_wo;
  select * into w from work_orders where id = p_wo;
  select coalesce(sum((x->>'qty')::numeric) filter (where x->>'kind' in ('labor', 'after_hours', 'helper')), 0), coalesce(bool_or(x->>'amount' is null), false)
    into labor, missing from jsonb_array_elements(coalesce(d.lines, '[]')) x;
  t := _tax_calc(w.contractor_id, w.site_id, w.customer_id, coalesce(d.lines, '[]'));
  return jsonb_build_object('lines', coalesce(d.lines, '[]'), 'invoice_number', d.invoice_number, 'note', d.note,
    'built_at', d.built_at, 'updated_at', d.updated_at, 'sent_at', d.sent_at,
    'subtotal', t->'subtotal', 'total', t->'total', 'tax', t,
    'labor_h', labor, 'verified_h', (v->>'billable_h')::numeric, 'missing_rates', missing,
    'cap', chk->'cap', 'over', (chk->>'cap') is not null and (t->>'subtotal')::numeric > (chk->>'cap')::numeric,
    'rates', _bill_rates(p_wo), 'suggested_no', _bill_suggest_no(w.contractor_id),
    'sent', exists (select 1 from call_invoices where work_order_id = p_wo), 'flat', _is_flat(p_wo));
end $$;

-- After the invoice row is written: the customer's copy of the lines (no cost), the tax on it, the private side
create or replace function _bill_tax_save(p_wo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders; d bill_drafts; t jsonb; ln jsonb;
begin
  select * into w from work_orders where id = p_wo;
  select * into d from bill_drafts where work_order_id = p_wo;
  t := _tax_calc(w.contractor_id, w.site_id, w.customer_id, d.lines);
  -- every line says how it was taxed (the bill marks the taxed ones)
  select coalesce(jsonb_agg(x || jsonb_build_object('tax', coalesce(nullif(x->>'tax', ''), _line_tax_default(x->>'kind', t->'area', null))) order by n), '[]')
    into ln from jsonb_array_elements(coalesce(d.lines, '[]')) with ordinality e(x, n);
  update call_invoices set lines = _lines_public(ln), subtotal = (t->>'subtotal')::numeric, sales_tax = (t->>'sales_tax')::numeric,
         tax_rate = case when (t->>'on')::boolean then (t->>'rate')::numeric end, tax_area = t->'area'->>'name',
         tax_exempt = (t->>'exempt')::boolean, total = (t->>'total')::numeric
   where work_order_id = p_wo;
  insert into invoice_tax (work_order_id, contractor_id, tax_area_id, tax_area, state, rate, exempt, subtotal, taxable, nontaxable, sales_tax, use_basis, use_tax, lines, sent_at)
  values (p_wo, w.contractor_id, (t->'area'->>'id')::uuid, t->'area'->>'name', t->'area'->>'state', (t->>'rate')::numeric, (t->>'exempt')::boolean,
          (t->>'subtotal')::numeric, (t->>'taxable')::numeric, (t->>'nontaxable')::numeric, (t->>'sales_tax')::numeric,
          (t->>'use_basis')::numeric, (t->>'use_tax')::numeric, ln, now())
  on conflict (work_order_id) do update set tax_area_id = excluded.tax_area_id, tax_area = excluded.tax_area, state = excluded.state, rate = excluded.rate,
    exempt = excluded.exempt, subtotal = excluded.subtotal, taxable = excluded.taxable, nontaxable = excluded.nontaxable, sales_tax = excluded.sales_tax,
    use_basis = excluded.use_basis, use_tax = excluded.use_tax, lines = excluded.lines, sent_at = now();
  return t;
end $$;

select from _patch_fn('send_built_bill(uuid,text,boolean)'::regprocedure,
  'if (s->>''total'')::numeric <= 0 then raise exception ''The bill comes to $0.''; end if;',
  'if (s->>''total'')::numeric <= 0 then raise exception ''The bill comes to $0.''; end if;
  if (s->''tax''->>''missing'')::boolean then raise exception ''Pick the tax rate for this location first (Tax on this bill).''; end if;');
select from _patch_fn('send_built_bill(uuid,text,boolean)'::regprocedure,
  'perform send_bill(p_wo, trim(d.invoice_number), (s->>''total'')::numeric,',
  'perform send_bill(p_wo, trim(d.invoice_number), (s->>''subtotal'')::numeric,');
select from _patch_fn('send_built_bill(uuid,text,boolean)'::regprocedure,
  'update call_invoices set lines = d.lines, built = true where work_order_id = p_wo;',
  'update call_invoices set built = true where work_order_id = p_wo;
  perform _bill_tax_save(p_wo);');
select from _patch_fn('_send_own_bill(uuid)'::regprocedure,
  'built = true, flat = excluded.flat;',
  'built = true, flat = excluded.flat;
  perform _bill_tax_save(p_wo);');

-- The PO limit is compared with the bill before tax
select from _patch_fn('_invoice_check(uuid)'::regprocedure, 'i.total > nte', 'coalesce(i.subtotal, i.total) > nte');
select from _patch_fn('_invoice_check(uuid)'::regprocedure, 'then i.total - nte', 'then coalesce(i.subtotal, i.total) - nte');

-- The printable bill shows the tax
create or replace function _bill_tax_view(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i call_invoices; w work_orders; d bill_drafts; t jsonb;
begin
  select * into i from call_invoices where work_order_id = p_wo;
  if i.work_order_id is not null then
    return jsonb_build_object('subtotal', coalesce(i.subtotal, i.total), 'sales_tax', coalesce(i.sales_tax, 0), 'tax_rate', i.tax_rate,
      'tax_area', i.tax_area, 'tax_exempt', coalesce(i.tax_exempt, false));
  end if;
  select * into w from work_orders where id = p_wo;
  select * into d from bill_drafts where work_order_id = p_wo;
  t := _tax_calc(w.contractor_id, w.site_id, w.customer_id, coalesce(d.lines, '[]'));
  return jsonb_build_object('subtotal', t->'subtotal', 'sales_tax', t->'sales_tax', 'tax_rate', case when (t->>'on')::boolean then t->'rate' end,
    'tax_area', t->'area'->'name', 'tax_exempt', t->'exempt', 'total', t->'total',
    'lines', _lines_public((select coalesce(jsonb_agg(x || jsonb_build_object('tax', coalesce(nullif(x->>'tax', ''), _line_tax_default(x->>'kind', t->'area', null))) order by n), '[]')
                            from jsonb_array_elements(coalesce(d.lines, '[]')) with ordinality e(x, n))));
end $$;
select from _patch_fn('bill_view(uuid)'::regprocedure,
  '''paid_at'', i.paid_at, ''emailed_to'', i.emailed_to);',
  '''paid_at'', i.paid_at, ''emailed_to'', i.emailed_to) || _bill_tax_view(p_wo);');
select from _patch_fn('bill_public(uuid)'::regprocedure,
  '''flat'', i.flat, ''paid'', i.paid_at is not null, ''paid_at'', i.paid_at,',
  '''flat'', i.flat, ''paid'', i.paid_at is not null, ''paid_at'', i.paid_at, ''subtotal'', coalesce(i.subtotal, i.total), ''sales_tax'', coalesce(i.sales_tax, 0),
    ''tax_rate'', i.tax_rate, ''tax_area'', i.tax_area, ''tax_exempt'', coalesce(i.tax_exempt, false),');

-- ---------- quotes ----------
create or replace function _quote_lines(p_lines jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(_bill_line(
           case when x->>'kind' in ('labor', 'part', 'task', 'equipment', 'other') then x->>'kind' else 'other' end,
           left(trim(x->>'description'), 300),
           greatest(0, coalesce(nullif(x->>'qty', '')::numeric, 0)),
           left(coalesce(x->>'unit', ''), 10),
           greatest(0, coalesce(nullif(x->>'rate', '')::numeric, 0)), false) || _clean_line_extras(x) order by n), '[]')
  from jsonb_array_elements(coalesce(p_lines, '[]')) with ordinality e(x, n) where coalesce(trim(x->>'description'), '') <> ''
$$;

select from _patch_fn('save_quote(uuid,uuid,text,jsonb,text,date,uuid)'::regprocedure,
  'declare m profiles := me(); s sites; q quotes; ln jsonb; tot numeric;',
  'declare m profiles := me(); s sites; q quotes; ln jsonb; tot numeric; tx jsonb;');
select from _patch_fn('save_quote(uuid,uuid,text,jsonb,text,date,uuid)'::regprocedure,
  'select coalesce(sum((x->>''amount'')::numeric), 0) into tot from jsonb_array_elements(ln) x;',
  'tx := _tax_calc(m.contractor_id, s.id, s.customer_id, ln);
  tot := (tx->>''total'')::numeric;');
select from _patch_fn('save_quote(uuid,uuid,text,jsonb,text,date,uuid)'::regprocedure,
  'return to_jsonb(q);',
  'update quotes set subtotal = (tx->>''subtotal'')::numeric, sales_tax = (tx->>''sales_tax'')::numeric,
         tax_rate = case when (tx->>''on'')::boolean then (tx->>''rate'')::numeric end, tax_area = tx->''area''->>''name'',
         tax_exempt = (tx->>''exempt'')::boolean, use_tax = (tx->>''use_tax'')::numeric
   where id = q.id returning * into q;
  return to_jsonb(q) || jsonb_build_object(''tax'', tx);');
select from _patch_fn('quote_public(uuid)'::regprocedure,
  '''lines'', q.lines, ''total'', q.total,',
  '''lines'', _lines_public(q.lines), ''total'', q.total, ''subtotal'', coalesce(q.subtotal, q.total), ''sales_tax'', coalesce(q.sales_tax, 0),
    ''tax_rate'', q.tax_rate, ''tax_area'', q.tax_area, ''tax_exempt'', coalesce(q.tax_exempt, false),');
select from _patch_fn('store_quotes()'::regprocedure,
  '''lines'', q.lines,',
  '''lines'', _lines_public(q.lines), ''subtotal'', coalesce(q.subtotal, q.total), ''sales_tax'', coalesce(q.sales_tax, 0),
        ''tax_rate'', q.tax_rate, ''tax_area'', q.tax_area, ''tax_exempt'', coalesce(q.tax_exempt, false),');
select from _patch_fn('my_quotes()'::regprocedure,
  '''lines'', q.lines,',
  '''lines'', q.lines, ''subtotal'', coalesce(q.subtotal, q.total), ''sales_tax'', coalesce(q.sales_tax, 0), ''tax_rate'', q.tax_rate,
        ''tax_area'', q.tax_area, ''tax_exempt'', coalesce(q.tax_exempt, false), ''use_tax'', q.use_tax,');

-- ---------- QuickBooks files carry the tax ----------
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
      'subtotal', coalesce(i.subtotal, i.total), 'sales_tax', coalesce(i.sales_tax, 0), 'tax_rate', i.tax_rate, 'tax_area', i.tax_area,
      'tax_exempt', coalesce(i.tax_exempt, false),
      'paid_at', i.paid_at, 'exported_at', i.exported_at) order by i.entered_at), '[]')
    from call_invoices i join work_orders w on w.id = i.work_order_id join customers cu on cu.id = w.customer_id
    join sites s on s.id = w.site_id join contractors c on c.id = w.contractor_id
    where w.contractor_id = m.contractor_id and i.built and i.entered_side = 'contractor'
      and (p_from is null or i.entered_at >= p_from) and (p_to is null or i.entered_at < p_to + 1)
      and (not coalesce(p_only_new, true) or i.exported_at is null));
end $$;

-- ---------- the tax report ----------
create or replace function tax_report(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) or not is_contractor_office(m.contractor_id) then
    raise exception 'Only your owner or billing can see the tax report.';
  end if;
  if not _is_base(m.contractor_id) then raise exception 'The tax report comes with Base.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Pick the dates.'; end if;
  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'paid_at_purchase', (select use_tax_paid_at_purchase from contractors where id = m.contractor_id),
    'areas', (select coalesce(jsonb_agg(to_jsonb(g) order by g.state nulls last, g.area), '[]') from (
        select coalesce(t.tax_area, 'No tax rate') area, t.state, t.rate, count(*) bills,
               sum(t.subtotal) sales, sum(t.taxable) filter (where not t.exempt) taxable, coalesce(sum(t.taxable) filter (where t.exempt), 0) exempt_sales,
               sum(t.nontaxable) nontaxable, sum(t.sales_tax) sales_tax, sum(t.use_basis) use_basis, sum(t.use_tax) use_tax
          from invoice_tax t join call_invoices i on i.work_order_id = t.work_order_id
         where t.contractor_id = m.contractor_id and i.entered_at >= p_from and i.entered_at < p_to + 1
         group by 1, 2, 3) g),
    'use_lines', (select coalesce(jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'date', i.entered_at::date, 'customer', cu.name,
          'site', s.name, 'area', t.tax_area, 'rate', t.rate, 'description', x->>'description', 'qty', (x->>'qty')::numeric,
          'cost', nullif(x->>'cost', '')::numeric, 'basis', round(coalesce((x->>'qty')::numeric, 0) * coalesce(nullif(x->>'cost', '')::numeric, 0), 2),
          'use_tax', round(round(coalesce((x->>'qty')::numeric, 0) * coalesce(nullif(x->>'cost', '')::numeric, 0), 2) * coalesce(t.rate, 0) / 100, 2))
          order by i.entered_at), '[]')
        from invoice_tax t join call_invoices i on i.work_order_id = t.work_order_id join work_orders w on w.id = t.work_order_id
        join customers cu on cu.id = w.customer_id join sites s on s.id = w.site_id, jsonb_array_elements(t.lines) x
       where t.contractor_id = m.contractor_id and i.entered_at >= p_from and i.entered_at < p_to + 1 and x->>'tax' = 'use'));
end $$;

grant execute on function tax_settings(), save_tax_area(uuid, text, text, text, numeric, boolean, boolean, text, boolean), remove_tax_area(uuid),
  mark_tax_rates_checked(), set_use_tax_paid_at_purchase(boolean), site_tax(uuid), set_site_tax_area(uuid, uuid),
  set_customer_tax_exempt(uuid, boolean, text, date), set_part_built_in(uuid, boolean), tax_report(date, date) to authenticated;
revoke execute on function tax_settings(), save_tax_area(uuid, text, text, text, numeric, boolean, boolean, text, boolean), remove_tax_area(uuid),
  mark_tax_rates_checked(), set_use_tax_paid_at_purchase(boolean), site_tax(uuid), set_site_tax_area(uuid, uuid),
  set_customer_tax_exempt(uuid, boolean, text, date), set_part_built_in(uuid, boolean), tax_report(date, date) from anon;
revoke execute on function _tax_area_for(uuid, uuid), _tax_calc(uuid, uuid, uuid, jsonb), _bill_tax_save(uuid), _bill_tax_view(uuid), _tax_office(boolean)
  from public, anon, authenticated;
