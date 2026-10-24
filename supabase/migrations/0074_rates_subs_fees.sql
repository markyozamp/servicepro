-- Base: "Your rates", and subcontractor / fee / permit lines.
--  * Sell rates by role: lead tech, helper, apprentice (regular and overtime / after hours) and the trip charge,
--    used on every bill unless the customer has its own rate card (which can now set any of them, and its own
--    parts markup or tiers). Rates are the contractor's own: none is filled in for him, and saving needs his
--    "I set these rates myself" confirmation, recorded with who and when. No built bill goes out before that.
--  * Parts markup: one percent, or tiers by the part's cost ($0-500 at 65 %, $500-1,000 at 50 %, above at 45 %...).
--  * Labor cost (private): each tech's pay and the company's burden %, for job costing (Pro), and the rate
--    calculator's numbers (overhead, billable hours, target margin), kept so he can come back to them.
--  * Guardrails: probable typos (labor under $40 or over $400 an hour, markup over 300 %) and a rate below his own
--    break-even need "keep it anyway".
--  * New bill / quote lines: subcontractor (electrical, plumbing, crane...) and fee / permit, each at his cost plus
--    a markup, or passed through at cost; the cost stays private.

alter table contractors add column if not exists rates jsonb not null default '{}';
alter table contractors add column if not exists labor_burden_pct numeric(5,1);
alter table contractors add column if not exists rate_calc jsonb;
alter table contractors add column if not exists rates_confirmed_at timestamptz;
alter table contractors add column if not exists rates_confirmed_by uuid;

create table if not exists tech_pay (                  -- private: what each person costs per hour
  profile_id    uuid primary key references profiles(id) on delete cascade,
  contractor_id uuid not null references contractors(id) on delete cascade,
  pay_rate      numeric(8,2) not null check (pay_rate >= 0 and pay_rate < 1000),
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);
alter table tech_pay enable row level security;

-- The markup for a part of this cost: the tiers if set (ascending "up to" amounts; the last may be open), else one percent
create or replace function _parts_pct(p_rates jsonb, p_cost numeric) returns numeric
language sql immutable as $$
  select coalesce(
    (select (t->>'pct')::numeric from jsonb_array_elements(case when jsonb_typeof(p_rates->'parts_tiers') = 'array' then p_rates->'parts_tiers' else '[]' end) with ordinality e(t, n)
      where nullif(t->>'up_to', '') is null or coalesce(p_cost, 0) <= (t->>'up_to')::numeric order by n limit 1),
    (p_rates->>'markup_pct')::numeric, 0)
$$;

-- The rates for this call: the customer's rate card (any key it sets), else the company's
create or replace function _bill_rates(p_wo uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'regular', coalesce((cr.rates->>'regular')::numeric, (c.rates->>'lead')::numeric, nullif(c.labor_rate, 0)),
    'after_hours', coalesce((cr.rates->>'after_hours')::numeric, (c.rates->>'lead_ot')::numeric, nullif(c.after_hours_labor_rate, 0)),
    'helper', coalesce((cr.rates->>'helper')::numeric, (c.rates->>'helper')::numeric),
    'helper_ot', coalesce((cr.rates->>'helper_after_hours')::numeric, (c.rates->>'helper_ot')::numeric, (cr.rates->>'helper')::numeric, (c.rates->>'helper')::numeric),
    'apprentice', coalesce((cr.rates->>'apprentice')::numeric, (c.rates->>'apprentice')::numeric),
    'apprentice_ot', coalesce((cr.rates->>'apprentice_after_hours')::numeric, (c.rates->>'apprentice_ot')::numeric, (cr.rates->>'apprentice')::numeric, (c.rates->>'apprentice')::numeric),
    'trip', coalesce((cr.rates->>'trip')::numeric, (c.rates->>'trip')::numeric, nullif(c.trip_charge, 0)),
    'markup_pct', coalesce((cr.rates->>'markup_pct')::numeric, c.parts_markup_pct, 0),
    'parts_tiers', case when jsonb_typeof(cr.rates->'parts_tiers') = 'array' then cr.rates->'parts_tiers'
                        when cr.rates ? 'markup_pct' then null else c.rates->'parts_tiers' end,
    'card_parts', cr.id is not null and (cr.rates ? 'markup_pct' or cr.rates ? 'parts_tiers'),
    'source', case when cr.id is not null then 'rate_card' else 'company' end)
  from work_orders w join contractors c on c.id = w.contractor_id
  left join lateral (select * from contractor_rates r where r.customer_id = w.customer_id and r.contractor_id = w.contractor_id
       and r.status in ('accepted', 'replaced') and r.effective_from <= w.created_at::date
       order by r.effective_from desc, r.decided_at desc nulls last limit 1) cr on true
  where w.id = p_wo
$$;

-- A part's sell price when it's used: the catalog's fixed price, else cost plus the company's markup (tiers)
create or replace function part_price(p_part uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(pt.unit_price, round(coalesce(pt.unit_cost, 0) * (1 + _parts_pct(c.rates || jsonb_build_object('markup_pct', c.parts_markup_pct), pt.unit_cost) / 100), 2))
  from parts pt join contractors c on c.id = pt.contractor_id where pt.id = p_part
$$;

-- On the bill, a customer whose rate card sets the parts markup gets parts priced from cost by that card
select from _patch_fn('_bill_auto_lines(uuid)'::regprocedure,
  'coalesce(pu.unit_price, round(pu.unit_cost * (1 + coalesce((r->>''markup_pct'')::numeric, 0) / 100), 2)) price',
  'case when coalesce((r->>''card_parts'')::boolean, false) and pu.unit_cost is not null and pt.unit_price is null
                       then round(pu.unit_cost * (1 + _parts_pct(r, pu.unit_cost) / 100), 2) else pu.unit_price end price');

-- ---------- the contractor's rates ----------
create or replace function _rates_office(p_billing boolean) returns profiles
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Not allowed.'; end if;
  if p_billing and not (m.is_org_admin or m.can_bill) then raise exception 'Only your owner or billing can set your rates.'; end if;
  return m;
end $$;

create or replace function my_rates() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := _rates_office(false); c contractors; owner boolean;
begin
  select * into c from contractors where id = m.contractor_id;
  owner := m.is_org_admin or m.can_bill;
  return jsonb_build_object(
    'rates', c.rates || jsonb_build_object('lead', coalesce((c.rates->>'lead')::numeric, nullif(c.labor_rate, 0)),
                                           'lead_ot', coalesce((c.rates->>'lead_ot')::numeric, nullif(c.after_hours_labor_rate, 0)),
                                           'trip', coalesce((c.rates->>'trip')::numeric, nullif(c.trip_charge, 0)),
                                           'markup_pct', c.parts_markup_pct),
    'confirmed_at', c.rates_confirmed_at, 'confirmed_by', (select full_name from profiles where id = c.rates_confirmed_by),
    'can_edit', owner,
    'burden_pct', case when owner then c.labor_burden_pct end,
    'calc', case when owner then c.rate_calc end,
    'team', case when owner then (select coalesce(jsonb_agg(jsonb_build_object('profile_id', p.id, 'name', p.full_name, 'title', p.title,
                'pay_rate', tp.pay_rate) order by p.full_name), '[]')
              from profiles p left join tech_pay tp on tp.profile_id = p.id
              where p.contractor_id = m.contractor_id and p.active and (p.is_technician or tp.pay_rate is not null)) end);
end $$;

-- Break-even and target rate from his own numbers (the same math as the screen)
create or replace function _rate_calc(p jsonb) returns jsonb
language plpgsql immutable as $$
declare pay numeric := nullif(p->>'pay', '')::numeric; burden numeric := coalesce(nullif(p->>'burden_pct', '')::numeric, 0);
  overhead numeric := coalesce(nullif(p->>'overhead_month', '')::numeric, 0); techs numeric := greatest(1, coalesce(nullif(p->>'techs', '')::numeric, 1));
  paid numeric := greatest(1, coalesce(nullif(p->>'paid_hours', '')::numeric, 40)); billable numeric := nullif(p->>'billable_hours', '')::numeric;
  margin numeric := coalesce(nullif(p->>'margin_pct', '')::numeric, 0); cost numeric;
begin
  if pay is null or billable is null or billable <= 0 then return null; end if;
  cost := (pay * (1 + burden / 100) * paid + overhead * 12 / 52 / techs) / billable;
  return jsonb_build_object('break_even', round(cost, 2),
    'target', case when margin < 100 then round(cost / (1 - margin / 100), 2) end);
end $$;

create or replace function save_rates(p_rates jsonb, p_confirm boolean, p_override boolean default false,
  p_burden_pct numeric default null, p_calc jsonb default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _rates_office(true); r jsonb := coalesce(p_rates, '{}'); k text; v numeric; prev numeric := -1; t jsonb; warn text[] := '{}';
  calc jsonb; be numeric; clean jsonb := '{}'; tiers jsonb := '[]';
begin
  if not coalesce(p_confirm, false) then raise exception 'Check "I set these rates myself" to save them.'; end if;
  if nullif(r->>'lead', '') is null or (r->>'lead')::numeric <= 0 then raise exception 'Enter your regular labor rate (lead tech, per hour).'; end if;
  foreach k in array array['lead', 'lead_ot', 'helper', 'helper_ot', 'apprentice', 'apprentice_ot', 'trip', 'markup_pct'] loop
    if nullif(r->>k, '') is not null then
      v := (r->>k)::numeric;
      if v < 0 then raise exception 'Rates can''t be negative.'; end if;
      clean := clean || jsonb_build_object(k, round(v, 2));
      if k not in ('trip', 'markup_pct') and v > 0 and (v < 40 or v > 400) then warn := warn || format('%s at $%s an hour', replace(replace(k, '_ot', ' overtime'), '_', ' '), trim_scale(v)); end if;
      if k = 'markup_pct' and v > 300 then warn := warn || format('a %s%% parts markup', trim_scale(v)); end if;
    end if;
  end loop;
  if jsonb_typeof(r->'parts_tiers') = 'array' then
    for t in select * from jsonb_array_elements(r->'parts_tiers') loop
      if nullif(t->>'pct', '') is null then continue; end if;
      if (t->>'pct')::numeric < 0 then raise exception 'A markup can''t be negative.'; end if;
      if (t->>'pct')::numeric > 300 then warn := warn || format('a %s%% parts markup', trim_scale((t->>'pct')::numeric)); end if;
      if nullif(t->>'up_to', '') is not null then
        if (t->>'up_to')::numeric <= prev then raise exception 'Parts tiers go up: each "up to" amount higher than the last.'; end if;
        prev := (t->>'up_to')::numeric;
      elsif prev = -2 then raise exception 'Only the last tier can be open-ended ("and above").';
      else prev := -2;
      end if;
      tiers := tiers || jsonb_build_object('up_to', nullif(t->>'up_to', '')::numeric, 'pct', (t->>'pct')::numeric);
    end loop;
    if jsonb_array_length(tiers) > 0 then clean := clean || jsonb_build_object('parts_tiers', tiers); end if;
  end if;
  calc := _rate_calc(coalesce(p_calc, '{}') || jsonb_build_object('burden_pct', coalesce(p_burden_pct, (p_calc->>'burden_pct')::numeric)));
  be := (calc->>'break_even')::numeric;
  if be is not null and (clean->>'lead')::numeric < be then
    warn := warn || format('your regular rate ($%s) is below your break-even of $%s an hour: you''d lose about $%s on every hour you bill',
      trim_scale((clean->>'lead')::numeric), trim_scale(be), trim_scale(round(be - (clean->>'lead')::numeric, 2)));
  end if;
  if array_length(warn, 1) > 0 and not coalesce(p_override, false) then
    raise exception 'Double-check: %. If that''s right, tick "Keep it anyway" and save again.', array_to_string(warn, '; ');
  end if;
  update contractors set rates = clean, labor_rate = (clean->>'lead')::numeric,
         after_hours_labor_rate = coalesce((clean->>'lead_ot')::numeric, after_hours_labor_rate),
         trip_charge = coalesce((clean->>'trip')::numeric, trip_charge),
         parts_markup_pct = coalesce((clean->>'markup_pct')::numeric, parts_markup_pct),
         labor_burden_pct = coalesce(p_burden_pct, labor_burden_pct),
         rate_calc = coalesce(p_calc, rate_calc),
         rates_confirmed_at = now(), rates_confirmed_by = m.id
   where id = m.contractor_id;
  return jsonb_build_object('ok', true, 'calc', calc, 'overridden', array_length(warn, 1) > 0);
end $$;

create or replace function set_tech_pay(p_profile uuid, p_pay numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _rates_office(true);
begin
  if not exists (select 1 from profiles where id = p_profile and contractor_id = m.contractor_id) then raise exception 'That person isn''t on your team.'; end if;
  if p_pay is null then
    update tech_pay set pay_rate = 0, updated_at = now(), updated_by = m.id where profile_id = p_profile;
  else
    if p_pay < 0 or p_pay >= 1000 then raise exception 'Enter the hourly pay.'; end if;
    insert into tech_pay (profile_id, contractor_id, pay_rate, updated_by) values (p_profile, m.contractor_id, round(p_pay, 2), m.id)
    on conflict (profile_id) do update set pay_rate = excluded.pay_rate, updated_at = now(), updated_by = m.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- No built bill goes out until he has set his rates
select from _patch_fn('send_built_bill(uuid,text,boolean)'::regprocedure,
  'begin
  perform bill_draft(p_wo);',
  'begin
  if (select rates_confirmed_at from contractors where id = w.contractor_id) is null then
    raise exception ''Set up your rates first: Team → Your rates (a minute, once).'';
  end if;
  perform bill_draft(p_wo);');

-- ---------- subcontractor and fee / permit lines ----------
-- kind 'sub' or 'fee'; 'sub_type' / 'fee_type' from the lists; 'vendor' (who); 'cost' (private) and 'markup' %
-- ('pass' = at cost); the price is cost plus markup unless a price is typed in.
create or replace function _clean_line_extras(x jsonb) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'tax', case when x->>'tax' in ('sales', 'use', 'none') then x->>'tax' end,
    'cost', case when nullif(x->>'cost', '') is null then null else greatest(0, (x->>'cost')::numeric) end,
    'part_id', case when x->>'part_id' ~ '^[0-9a-f-]{36}$' then x->>'part_id' end,
    'markup', case when x->>'kind' in ('sub', 'fee') and nullif(x->>'markup', '') is not null then greatest(0, (x->>'markup')::numeric) end,
    'sub_type', case when x->>'kind' = 'sub' then left(nullif(trim(x->>'sub_type'), ''), 40) end,
    'fee_type', case when x->>'kind' = 'fee' then left(nullif(trim(x->>'fee_type'), ''), 40) end,
    'vendor', case when x->>'kind' in ('sub', 'fee') then left(nullif(trim(x->>'vendor'), ''), 80) end))
$$;

-- Sub / fee lines priced from cost and markup when no price is typed
create or replace function _price_sub_fee(x jsonb) returns jsonb language sql immutable as $$
  select case when x->>'kind' in ('sub', 'fee') and nullif(x->>'rate', '') is null and nullif(x->>'cost', '') is not null
              then x || jsonb_build_object('rate', round((x->>'cost')::numeric * (1 + coalesce(nullif(x->>'markup', '')::numeric, 0) / 100), 2))
              else x end
$$;

create or replace function save_bill(p_wo uuid, p_lines jsonb, p_invoice_number text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _bill_guard(p_wo); clean jsonb;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) > 60 then raise exception 'Up to 60 lines on a bill.'; end if;
  select coalesce(jsonb_agg(_bill_line(
           case when y->>'kind' in ('labor', 'after_hours', 'helper', 'apprentice', 'trip', 'part', 'flat', 'task', 'equipment', 'sub', 'fee', 'other') then y->>'kind' else 'other' end,
           left(trim(y->>'description'), 200),
           greatest(0, coalesce(nullif(y->>'qty', '')::numeric, 0)),
           left(coalesce(y->>'unit', ''), 10),
           case when nullif(y->>'rate', '') is null then null else greatest(0, (y->>'rate')::numeric) end,
           coalesce((y->>'auto')::boolean, false)) || _clean_line_extras(y) order by n), '[]')
    into clean
    from jsonb_array_elements(p_lines) with ordinality e(x, n), lateral (select _price_sub_fee(x) y) z
   where coalesce(trim(x->>'description'), '') <> '';
  perform bill_draft(p_wo);
  update bill_drafts set lines = clean, invoice_number = coalesce(nullif(trim(p_invoice_number), ''), invoice_number),
         note = nullif(trim(p_note), ''), updated_at = now(), updated_by = auth.uid()
   where work_order_id = p_wo;
  return _bill_summary(p_wo);
end $$;

create or replace function _quote_lines(p_lines jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(_bill_line(
           case when y->>'kind' in ('labor', 'part', 'task', 'equipment', 'sub', 'fee', 'other') then y->>'kind' else 'other' end,
           left(trim(y->>'description'), 300),
           greatest(0, coalesce(nullif(y->>'qty', '')::numeric, 0)),
           left(coalesce(y->>'unit', ''), 10),
           greatest(0, coalesce(nullif(y->>'rate', '')::numeric, 0)), false) || _clean_line_extras(y) order by n), '[]')
  from jsonb_array_elements(coalesce(p_lines, '[]')) with ordinality e(x, n), lateral (select _price_sub_fee(x) y) z
  where coalesce(trim(x->>'description'), '') <> ''
$$;

-- Tax defaults for the new lines: fees and permits aren't taxed; a sub follows the labor rule
create or replace function _line_tax_default(p_kind text, p_area jsonb, p_built_in boolean default null) returns text
language sql immutable as $$
  select case
    when p_kind in ('labor', 'after_hours', 'helper', 'apprentice', 'flat', 'sub') then case when coalesce((p_area->>'labor')::boolean, false) then 'sales' else 'none' end
    when p_kind = 'trip' then case when coalesce((p_area->>'trip')::boolean, false) then 'sales' else 'none' end
    when p_kind = 'fee' then 'none'
    when p_kind in ('part', 'equipment') and coalesce(p_built_in, false) then 'use'
    else 'sales' end
$$;

-- What the customer may read of the lines: no cost, markup or vendor
create or replace function _lines_public(p_lines jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(x - 'cost' - 'auto' - 'part_id' - 'markup' - 'vendor' order by n), '[]') from jsonb_array_elements(coalesce(p_lines, '[]')) with ordinality as e(x, n)
$$;

grant execute on function my_rates(), save_rates(jsonb, boolean, boolean, numeric, jsonb), set_tech_pay(uuid, numeric) to authenticated;
revoke execute on function my_rates(), save_rates(jsonb, boolean, boolean, numeric, jsonb), set_tech_pay(uuid, numeric) from anon;
revoke execute on function _rates_office(boolean) from public, anon, authenticated;

-- A customer's rate card can set the new roles too
select from _patch_fn('_clean_rates(jsonb)'::regprocedure,
  'array[''regular'',''after_hours'',''helper'',''trip'',''markup_pct'']',
  'array[''regular'',''after_hours'',''helper'',''helper_after_hours'',''apprentice'',''apprentice_after_hours'',''trip'',''markup_pct'']');
