-- Base: "we write the bill for you". For a contractor on Base (or above), the bill for a call is built from what the
-- program already recorded: verified hours at this customer's rates (regular, after hours, helper), the trip fee per
-- trip, parts used, a PM's flat price. The contractor checks the lines, can change or add any, then taps Send: it goes
-- through the same bill check as the light bill (hours vs verified, the PO limit, auto-approve), and the store gets the
-- itemized bill with a printable copy (PDF). Same database, same app: the contractor's level turns it on.

alter table contractors add column if not exists level text not null default 'verify'
  check (level in ('verify', 'base', 'pro', 'enterprise'));
alter table contractors add column if not exists invoice_prefix text;
alter table contractors add column if not exists next_invoice_no int;
alter table call_invoices add column if not exists lines jsonb;
alter table call_invoices add column if not exists built boolean not null default false;

create table if not exists bill_drafts (
  work_order_id uuid primary key references work_orders(id) on delete cascade,
  lines         jsonb not null default '[]',
  invoice_number text,
  note          text,
  built_at      timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  sent_at       timestamptz
);
alter table bill_drafts enable row level security;     -- reached only through the functions below

create or replace function _is_base(p_contractor uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select level <> 'verify' from contractors where id = p_contractor), false)
$$;

-- Platform admin: move a contractor to a level (until Stripe does it on subscribe)
create or replace function set_contractor_level(p_contractor uuid, p_level text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce((select is_platform_admin from profiles where id = auth.uid() and active), false) then raise exception 'Not allowed.'; end if;
  if p_level not in ('verify', 'base', 'pro', 'enterprise') then raise exception 'Unknown level.'; end if;
  update contractors set level = p_level where id = p_contractor;
  return jsonb_build_object('ok', true);
end $$;

-- The contractor's invoice numbering for built bills (e.g. prefix "PP-", next 1042)
create or replace function set_invoice_numbering(p_prefix text, p_next int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) then raise exception 'Only your owner or billing can change this.'; end if;
  if p_next is not null and p_next < 1 then raise exception 'The next number has to be 1 or more.'; end if;
  update contractors set invoice_prefix = nullif(trim(p_prefix), ''), next_invoice_no = p_next where id = m.contractor_id;
  return jsonb_build_object('ok', true, 'next', coalesce(nullif(trim(p_prefix), ''), '') || coalesce(p_next, 1001));
end $$;

-- The rates for this call: this customer's rate card as of the call, else the contractor's company rates
create or replace function _bill_rates(p_wo uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'regular', coalesce((cr.rates->>'regular')::numeric, nullif(c.labor_rate, 0)),
    'after_hours', coalesce((cr.rates->>'after_hours')::numeric, nullif(c.after_hours_labor_rate, 0)),
    'helper', (cr.rates->>'helper')::numeric,
    'trip', coalesce((cr.rates->>'trip')::numeric, nullif(c.trip_charge, 0)),
    'markup_pct', coalesce((cr.rates->>'markup_pct')::numeric, c.parts_markup_pct, 0),
    'source', case when cr.id is not null then 'rate_card' else 'company' end)
  from work_orders w join contractors c on c.id = w.contractor_id
  left join lateral (select * from contractor_rates r where r.customer_id = w.customer_id and r.contractor_id = w.contractor_id
       and r.status in ('accepted', 'replaced') and r.effective_from <= w.created_at::date
       order by r.effective_from desc, r.decided_at desc nulls last limit 1) cr on true
  where w.id = p_wo
$$;

create or replace function _bill_line(p_kind text, p_desc text, p_qty numeric, p_unit text, p_rate numeric, p_auto boolean default true)
returns jsonb language sql immutable as $$
  select jsonb_build_object('kind', p_kind, 'description', p_desc, 'qty', p_qty, 'unit', p_unit, 'rate', p_rate,
    'amount', case when p_rate is null then null else round(p_qty * p_rate, 2) end, 'auto', p_auto)
$$;

-- Lines the program can fill in from the record
create or replace function _bill_auto_lines(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; v jsonb := _verified(p_wo); r jsonb := _bill_rates(p_wo); tech numeric; ah numeric; helper numeric; trips int;
  out jsonb := '[]'; p record;
begin
  select * into w from work_orders where id = p_wo;
  tech := coalesce((v->>'tech_billable_h')::numeric, 0);
  ah := least(coalesce((v->>'after_hours_h')::numeric, 0), tech);
  helper := coalesce((v->>'helper_billable_h')::numeric, 0);
  trips := jsonb_array_length(coalesce(v->'visits', '[]'));
  if w.flat_amount > 0 then out := out || _bill_line('flat', 'Preventive maintenance visit', 1, 'visit', w.flat_amount); end if;
  if tech - ah > 0 then out := out || _bill_line('labor', 'Labor (verified on site)', tech - ah, 'hr', (r->>'regular')::numeric); end if;
  if ah > 0 then out := out || _bill_line('after_hours', 'Labor, after hours (verified on site)', ah, 'hr', (r->>'after_hours')::numeric); end if;
  if helper > 0 then out := out || _bill_line('helper', 'Helper labor (crew confirmed on site)', helper, 'hr', (r->>'helper')::numeric); end if;
  if trips > 0 and coalesce((r->>'trip')::numeric, 0) > 0 then out := out || _bill_line('trip', 'Trip charge', trips, 'trip', (r->>'trip')::numeric); end if;
  for p in select pt.name, pu.quantity, coalesce(pu.unit_price, round(pu.unit_cost * (1 + coalesce((r->>'markup_pct')::numeric, 0) / 100), 2)) price
             from parts_used pu join parts pt on pt.id = pu.part_id where pu.work_order_id = p_wo and not coalesce(pu.covered, false)
             order by pu.added_at loop
    out := out || _bill_line('part', p.name, p.quantity, 'ea', p.price);
  end loop;
  return out;
end $$;

create or replace function _bill_suggest_no(p_contractor uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(invoice_prefix, '') || coalesce(next_invoice_no, 1001) from contractors where id = p_contractor
$$;

create or replace function _bill_summary(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d bill_drafts; w work_orders; v jsonb := _verified(p_wo); chk jsonb := _invoice_check(p_wo); total numeric; labor numeric; missing boolean;
begin
  select * into d from bill_drafts where work_order_id = p_wo;
  select * into w from work_orders where id = p_wo;
  select coalesce(sum((x->>'amount')::numeric), 0), coalesce(sum((x->>'qty')::numeric) filter (where x->>'kind' in ('labor', 'after_hours', 'helper')), 0),
         coalesce(bool_or(x->>'amount' is null), false)
    into total, labor, missing from jsonb_array_elements(coalesce(d.lines, '[]')) x;
  return jsonb_build_object('lines', coalesce(d.lines, '[]'), 'invoice_number', d.invoice_number, 'note', d.note,
    'built_at', d.built_at, 'updated_at', d.updated_at, 'sent_at', d.sent_at,
    'total', total, 'labor_h', labor, 'verified_h', (v->>'billable_h')::numeric, 'missing_rates', missing,
    'cap', chk->'cap', 'over', (chk->>'cap') is not null and total > (chk->>'cap')::numeric,
    'rates', _bill_rates(p_wo), 'suggested_no', _bill_suggest_no(w.contractor_id),
    'sent', exists (select 1 from call_invoices where work_order_id = p_wo));
end $$;

create or replace function _bill_guard(p_wo uuid) returns work_orders
language plpgsql stable security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
  if not _is_base(w.contractor_id) then raise exception 'Built bills come with Base. Upgrade to have your bill written for you.'; end if;
  if w.status not in ('completed', 'invoiced') then raise exception 'The bill is built once the work is completed.'; end if;
  return w;
end $$;

-- Contractor: the bill for this call (built the first time it's opened)
create or replace function bill_draft(p_wo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _bill_guard(p_wo);
begin
  insert into bill_drafts (work_order_id, lines, invoice_number, updated_by)
  values (p_wo, _bill_auto_lines(p_wo),
          coalesce((select invoice_number from call_invoices where work_order_id = p_wo), _bill_suggest_no(w.contractor_id)), auth.uid())
  on conflict (work_order_id) do nothing;
  return _bill_summary(p_wo);
end $$;

-- Contractor: start over from the record (keeps lines they added themselves)
create or replace function rebuild_bill(p_wo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _bill_guard(p_wo);
begin
  perform bill_draft(p_wo);
  update bill_drafts set lines = _bill_auto_lines(p_wo)
         || coalesce((select jsonb_agg(x) from jsonb_array_elements(lines) x where not coalesce((x->>'auto')::boolean, false)), '[]'),
         built_at = now(), updated_at = now(), updated_by = auth.uid()
   where work_order_id = p_wo;
  return _bill_summary(p_wo);
end $$;

-- Contractor: save their changes to the lines, the invoice # and the note
create or replace function save_bill(p_wo uuid, p_lines jsonb, p_invoice_number text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _bill_guard(p_wo); clean jsonb;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) > 60 then raise exception 'Up to 60 lines on a bill.'; end if;
  select coalesce(jsonb_agg(_bill_line(
           case when x->>'kind' in ('labor', 'after_hours', 'helper', 'trip', 'part', 'flat', 'other') then x->>'kind' else 'other' end,
           left(trim(x->>'description'), 200),
           greatest(0, coalesce(nullif(x->>'qty', '')::numeric, 0)),
           left(coalesce(x->>'unit', ''), 10),
           case when nullif(x->>'rate', '') is null then null else greatest(0, (x->>'rate')::numeric) end,
           coalesce((x->>'auto')::boolean, false))), '[]')
    into clean
    from jsonb_array_elements(p_lines) x where coalesce(trim(x->>'description'), '') <> '';
  perform bill_draft(p_wo);
  update bill_drafts set lines = clean, invoice_number = coalesce(nullif(trim(p_invoice_number), ''), invoice_number),
         note = nullif(trim(p_note), ''), updated_at = now(), updated_by = auth.uid()
   where work_order_id = p_wo;
  return _bill_summary(p_wo);
end $$;

-- Contractor: send it. Same bill check as the light bill; the store gets the itemized bill.
create or replace function send_built_bill(p_wo uuid, p_reason text default null, p_over_ok boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _bill_guard(p_wo); s jsonb; d bill_drafts; agree boolean;
begin
  perform bill_draft(p_wo);
  s := _bill_summary(p_wo);
  select * into d from bill_drafts where work_order_id = p_wo;
  if jsonb_array_length(d.lines) = 0 then raise exception 'The bill has no lines.'; end if;
  if (s->>'missing_rates')::boolean then raise exception 'Fill in a rate for every line first.'; end if;
  if coalesce(trim(d.invoice_number), '') = '' then raise exception 'Enter the invoice number.'; end if;
  if (s->>'total')::numeric <= 0 then raise exception 'The bill comes to $0.'; end if;
  agree := abs((s->>'labor_h')::numeric - coalesce((s->>'verified_h')::numeric, 0)) < 0.01;
  if (s->>'labor_h')::numeric > coalesce((s->>'verified_h')::numeric, 0) + 0.009 and coalesce(length(trim(p_reason)), 0) < 5 then
    raise exception 'Your labor is more than the verified hours. Say what the extra time was for.';
  end if;
  perform send_bill(p_wo, trim(d.invoice_number), (s->>'total')::numeric, agree,
                   case when agree then null else (s->>'labor_h')::numeric end, nullif(trim(p_reason), ''), coalesce(p_over_ok, false));
  update call_invoices set lines = d.lines, built = true where work_order_id = p_wo;
  update bill_drafts set sent_at = now() where work_order_id = p_wo;
  perform set_config('app.demo_guard_off', 'on', true);    -- the invoice counter moves on in the demo too
  update contractors set next_invoice_no = coalesce(next_invoice_no, 1001) + 1
   where id = w.contractor_id and coalesce(invoice_prefix, '') || coalesce(next_invoice_no, 1001) = trim(d.invoice_number);
  perform set_config('app.demo_guard_off', 'off', true);
  return _invoice_check(p_wo);
end $$;

-- The printable bill (both sides). The store sees it once it's sent; the contractor also sees their draft.
create or replace function bill_view(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w work_orders; i call_invoices; d bill_drafts; c contractors; office boolean; v jsonb;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not can_see_work_order(p_wo) then raise exception 'Not allowed.'; end if;
  office := is_contractor_office(w.contractor_id);
  select * into i from call_invoices where work_order_id = p_wo;
  select * into d from bill_drafts where work_order_id = p_wo;
  if i.work_order_id is null and not (office and d.work_order_id is not null) then return null; end if;
  select * into c from contractors where id = w.contractor_id;
  v := _verified(p_wo);
  return jsonb_build_object(
    'draft', i.work_order_id is null,
    'contractor', jsonb_build_object('name', c.name, 'phone', c.phone, 'email', c.email, 'logo', c.logo_data),
    'customer', (select name from customers where id = w.customer_id),
    'site', (select jsonb_build_object('name', s.name, 'address', s.address) from sites s where s.id = w.site_id),
    'call_number', w.number, 'po', coalesce(w.store_po_number, 'PO' || w.number), 'unit', w.unit,
    'problem', w.issue_description, 'summary', w.work_summary,
    'invoice_number', coalesce(i.invoice_number, d.invoice_number), 'date', coalesce(i.entered_at, d.updated_at),
    'lines', coalesce(i.lines, d.lines), 'built', coalesce(i.built, i.work_order_id is null),
    'total', coalesce(i.total, (select sum((x->>'amount')::numeric) from jsonb_array_elements(d.lines) x)),
    'hours_billed', i.hours_billed, 'status', i.status, 'note', d.note,
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('tech', x->>'tech', 'arrived', x->>'arrived_at', 'left', x->>'left_at',
                  'onsite_min', x->>'onsite_min', 'verified', coalesce((x->>'checkin_verified')::boolean, false), 'helpers', x->>'helpers')), '[]')
               from jsonb_array_elements(v->'visits') x),
    'verified_h', v->'billable_h');
end $$;

grant execute on function bill_draft(uuid), rebuild_bill(uuid), save_bill(uuid, jsonb, text, text), send_built_bill(uuid, text, boolean),
  bill_view(uuid), set_invoice_numbering(text, int), set_contractor_level(uuid, text) to authenticated;
revoke execute on function bill_draft(uuid), rebuild_bill(uuid), save_bill(uuid, jsonb, text, text), send_built_bill(uuid, text, boolean),
  bill_view(uuid), set_invoice_numbering(text, int), set_contractor_level(uuid, text) from anon;
revoke execute on function _bill_auto_lines(uuid), _bill_summary(uuid), _bill_guard(uuid) from public, anon, authenticated;

-- The bill check tells the screens when a bill was built (itemized)
select from _patch_fn('_invoice_check(uuid)'::regprocedure,
  '''auto_approved'', i.auto_approved, ''side'', i.entered_side)',
  '''auto_approved'', i.auto_approved, ''side'', i.entered_side, ''built'', i.built)');
