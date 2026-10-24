-- Flat-rate contractors: a price book of tasks, each with a flat price that already covers labor and parts
-- ("Replace run capacitor $285", "Diagnostic / service call $129"), optional prices for one customer, and per customer
-- whether the contractor bills hourly (time and materials) or flat rate. On a flat-rate call the tech (or the office)
-- picks the tasks done; the bill is those tasks. Hours aren't billed, so they aren't checked against the verified
-- time, but the store still sees the verified time on site next to the bill, for reference. The PO limit still applies.

-- ============ Price book ============
create table if not exists price_book_items (
  id            uuid primary key default gen_random_uuid(),
  contractor_id uuid not null references contractors(id) on delete cascade,
  code          text,
  name          text not null,
  description   text,
  category      text,
  price         numeric(10,2) not null check (price >= 0),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists price_book_items_c on price_book_items (contractor_id, active);
alter table price_book_items enable row level security;

create table if not exists price_book_customer (
  item_id     uuid not null references price_book_items(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  price       numeric(10,2) check (price >= 0),          -- null = back to the book price
  set_at      timestamptz not null default now(),
  primary key (item_id, customer_id)
);
alter table price_book_customer enable row level security;

alter table customer_contractors add column if not exists billing_method text not null default 'hourly'
  check (billing_method in ('hourly', 'flat'));
alter table call_invoices add column if not exists flat boolean not null default false;

-- Tasks done on a call (flat rate)
create table if not exists call_tasks (
  id            uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references work_orders(id) on delete cascade,
  visit_id      uuid,
  item_id       uuid references price_book_items(id) on delete set null,
  name          text not null,
  qty           numeric not null default 1 check (qty > 0),
  price         numeric(10,2) not null check (price >= 0),
  added_by      uuid,
  added_at      timestamptz not null default now(),
  removed_at    timestamptz,                  -- taken off (kept for the record)
  removed_by    uuid
);
create index if not exists call_tasks_wo on call_tasks (work_order_id);
alter table call_tasks enable row level security;

create or replace function _is_flat(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select cc.billing_method = 'flat' from work_orders w join customer_contractors cc
                    on cc.customer_id = w.customer_id and cc.contractor_id = w.contractor_id where w.id = p_wo), false)
$$;

create or replace function _price_office() returns profiles
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill or m.can_dispatch) then raise exception 'Only your office can change the price book.'; end if;
  return m;
end $$;

-- Office: add or change a task (p_id null = new)
create or replace function save_price_item(p_id uuid, p_name text, p_price numeric, p_code text default null,
  p_category text default null, p_description text default null, p_active boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _price_office(); r price_book_items;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the task a name.'; end if;
  if p_price is null or p_price < 0 then raise exception 'Enter a price.'; end if;
  if p_id is null then
    insert into price_book_items (contractor_id, code, name, description, category, price, active)
    values (m.contractor_id, nullif(trim(p_code), ''), trim(p_name), nullif(trim(p_description), ''), nullif(trim(p_category), ''), p_price, coalesce(p_active, true))
    returning * into r;
  else
    update price_book_items set code = nullif(trim(p_code), ''), name = trim(p_name), description = nullif(trim(p_description), ''),
           category = nullif(trim(p_category), ''), price = p_price, active = coalesce(p_active, true), updated_at = now()
     where id = p_id and contractor_id = m.contractor_id returning * into r;
    if r.id is null then raise exception 'Not your price book.'; end if;
  end if;
  return to_jsonb(r);
end $$;

-- Office: bring in a price book from a spreadsheet (rows of {code, name, price, category, description}).
-- A row whose code (or name, when there's no code) is already in the book updates it.
create or replace function import_price_book(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _price_office(); x jsonb; n_new int := 0; n_upd int := 0; skipped int := 0; hit uuid; pr numeric;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 2000 then raise exception 'Up to 2,000 rows at a time.'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    pr := nullif(regexp_replace(coalesce(x->>'price', ''), '[^0-9.]', '', 'g'), '')::numeric;
    if coalesce(trim(x->>'name'), '') = '' or pr is null then skipped := skipped + 1; continue; end if;
    select id into hit from price_book_items where contractor_id = m.contractor_id
       and (case when nullif(trim(x->>'code'), '') is not null then code = trim(x->>'code') else lower(name) = lower(trim(x->>'name')) end) limit 1;
    if hit is null then
      insert into price_book_items (contractor_id, code, name, description, category, price)
      values (m.contractor_id, nullif(trim(x->>'code'), ''), trim(x->>'name'), nullif(trim(x->>'description'), ''), nullif(trim(x->>'category'), ''), pr);
      n_new := n_new + 1;
    else
      update price_book_items set name = trim(x->>'name'), price = pr, category = coalesce(nullif(trim(x->>'category'), ''), category),
             description = coalesce(nullif(trim(x->>'description'), ''), description), active = true, updated_at = now() where id = hit;
      n_upd := n_upd + 1;
    end if;
  end loop;
  return jsonb_build_object('added', n_new, 'updated', n_upd, 'skipped', skipped);
end $$;

-- Office: a price for one customer (null clears it, back to the book price)
create or replace function set_customer_price(p_item uuid, p_customer uuid, p_price numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _price_office();
begin
  if not exists (select 1 from price_book_items where id = p_item and contractor_id = m.contractor_id) then raise exception 'Not your price book.'; end if;
  if not exists (select 1 from customer_contractors where customer_id = p_customer and contractor_id = m.contractor_id) then raise exception 'Not one of your customers.'; end if;
  if p_price is null then
    update price_book_customer set price = null, set_at = now() where item_id = p_item and customer_id = p_customer;   -- back to the book price
  else
    if p_price < 0 then raise exception 'Enter a price.'; end if;
    insert into price_book_customer (item_id, customer_id, price) values (p_item, p_customer, p_price)
    on conflict (item_id, customer_id) do update set price = excluded.price, set_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Office: bill this customer hourly or flat rate. The customer is told.
create or replace function set_billing_method(p_customer uuid, p_method text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := _price_office(); cc customer_contractors;
begin
  if p_method not in ('hourly', 'flat') then raise exception 'Hourly or flat rate.'; end if;
  update customer_contractors set billing_method = p_method where customer_id = p_customer and contractor_id = m.contractor_id returning * into cc;
  if cc.contractor_id is null then raise exception 'Not one of your customers.'; end if;
  perform _notify(p.id, null, 'billing_due', format('%s now bills you %s.', (select name from contractors where id = m.contractor_id),
    case when p_method = 'flat' then 'flat rate from their price book (you still see the verified time on site)' else 'by the hour (time and materials)' end))
    from profiles p where p.customer_id = p_customer and p.active and (p.is_org_admin or p.can_see_billing);
  return jsonb_build_object('ok', true, 'method', p_method);
end $$;

-- The price book as one customer sees it priced (contractor members only). p_customer null = book prices.
create or replace function price_book(p_customer uuid default null, p_all boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null then raise exception 'Not allowed.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'name', i.name, 'description', i.description,
      'category', i.category, 'book_price', i.price, 'price', coalesce(pc.price, i.price), 'customer_price', pc.price, 'active', i.active)
      order by i.category nulls last, i.name)
    from price_book_items i left join price_book_customer pc on pc.item_id = i.id and pc.customer_id = p_customer
    where i.contractor_id = m.contractor_id and (i.active or coalesce(p_all, false))), '[]');
end $$;

-- Tech or office: a task done on this call, from the price book (price for this customer)
create or replace function add_call_task(p_wo uuid, p_item uuid, p_qty numeric default 1) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; i price_book_items; pr numeric; v uuid;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or m.contractor_id is distinct from w.contractor_id then raise exception 'Not allowed.'; end if;
  if w.status = 'cancelled' or exists (select 1 from call_invoices where work_order_id = w.id and status = 'approved') then
    raise exception 'This call is closed: its bill is already approved.';
  end if;
  select * into i from price_book_items where id = p_item and contractor_id = w.contractor_id and active;
  if i.id is null then raise exception 'That task isn''t in your price book.'; end if;
  if coalesce(p_qty, 1) <= 0 then raise exception 'Quantity has to be more than 0.'; end if;
  pr := coalesce((select price from price_book_customer where item_id = i.id and customer_id = w.customer_id), i.price);
  select id into v from visits where work_order_id = p_wo and technician_id = m.id and status = 'on_site' order by visit_no desc limit 1;
  insert into call_tasks (work_order_id, visit_id, item_id, name, qty, price, added_by)
  values (p_wo, v, i.id, coalesce(i.code || ' ', '') || i.name, coalesce(p_qty, 1), pr, m.id);
  return call_tasks(p_wo);
end $$;

create or replace function remove_call_task(p_task uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); t call_tasks; w work_orders;
begin
  select * into t from call_tasks where id = p_task;
  select * into w from work_orders where id = t.work_order_id;
  if t.id is null or m.contractor_id is distinct from w.contractor_id then raise exception 'Not allowed.'; end if;
  if w.status = 'cancelled' or exists (select 1 from call_invoices where work_order_id = w.id and status = 'approved') then
    raise exception 'This call is closed: its bill is already approved.';
  end if;
  update call_tasks set removed_at = now(), removed_by = m.id where id = p_task;
  return call_tasks(w.id);
end $$;

create or replace function call_tasks(p_wo uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when can_see_work_order(p_wo) then coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'qty', t.qty, 'price', t.price,
      'amount', round(t.qty * t.price, 2), 'by', (select full_name from profiles where id = t.added_by), 'at', t.added_at) order by t.added_at)
    from call_tasks t where t.work_order_id = p_wo and t.removed_at is null), '[]') end
$$;

-- ============ The bill on a flat-rate call ============
-- Tasks instead of labor and trip lines (a PM's flat price still shows). Parts are inside the task prices.
select from _patch_fn('_bill_auto_lines(uuid)'::regprocedure,
  '  if w.flat_amount > 0 then out := out || _bill_line(''flat'', ''Preventive maintenance visit'', 1, ''visit'', w.flat_amount); end if;',
  '  if w.flat_amount > 0 then out := out || _bill_line(''flat'', ''Preventive maintenance visit'', 1, ''visit'', w.flat_amount); end if;
  if _is_flat(p_wo) then
    for p in select t.name, t.qty quantity, t.price from call_tasks t where t.work_order_id = p_wo and t.removed_at is null order by t.added_at loop
      out := out || _bill_line(''task'', p.name, p.quantity, ''ea'', p.price);
    end loop;
    return out;
  end if;');

-- Task lines are allowed on a saved bill
select from _patch_fn('save_bill(uuid,jsonb,text,text)'::regprocedure,
  'when x->>''kind'' in (''labor'', ''after_hours'', ''helper'', ''trip'', ''part'', ''flat'', ''other'')',
  'when x->>''kind'' in (''labor'', ''after_hours'', ''helper'', ''trip'', ''part'', ''flat'', ''task'', ''other'')');

-- A flat-rate bill doesn't bill hours: no hours check, no reason needed
select from _patch_fn('send_built_bill(uuid,text,boolean)'::regprocedure,
  '  agree := abs((s->>''labor_h'')::numeric - coalesce((s->>''verified_h'')::numeric, 0)) < 0.01;',
  '  agree := _is_flat(p_wo) or abs((s->>''labor_h'')::numeric - coalesce((s->>''verified_h'')::numeric, 0)) < 0.01;');
select from _patch_fn('send_built_bill(uuid,text,boolean)'::regprocedure,
  '  if (s->>''labor_h'')::numeric > coalesce((s->>''verified_h'')::numeric, 0) + 0.009 and coalesce(length(trim(p_reason)), 0) < 5 then',
  '  if not _is_flat(p_wo) and (s->>''labor_h'')::numeric > coalesce((s->>''verified_h'')::numeric, 0) + 0.009 and coalesce(length(trim(p_reason)), 0) < 5 then');

-- The summary says when it's a flat-rate call
select from _patch_fn('_bill_summary(uuid)'::regprocedure,
  '''sent'', exists (select 1 from call_invoices where work_order_id = p_wo));',
  '''sent'', exists (select 1 from call_invoices where work_order_id = p_wo), ''flat'', _is_flat(p_wo));');

-- Any bill sent for a flat-rate customer is marked flat (the light bill too)
select from _patch_fn('send_bill(uuid,text,numeric,boolean,numeric,text,boolean)'::regprocedure,
  'update call_invoices set agreed_hours = case when side = ''contractor'' then coalesce(p_agree_hours, false) end,',
  'update call_invoices set flat = _is_flat(p_wo), agreed_hours = case when side = ''contractor'' then coalesce(p_agree_hours, false) end,');

-- The bill check and the printable bill know it's flat rate
select from _patch_fn('_invoice_check(uuid)'::regprocedure,
  '''side'', i.entered_side, ''built'', i.built)',
  '''side'', i.entered_side, ''built'', i.built, ''flat'', i.flat)');
select from _patch_fn('bill_view(uuid)'::regprocedure,
  '''verified_h'', v->''billable_h'');',
  '''verified_h'', v->''billable_h'', ''flat'', coalesce(i.flat, _is_flat(p_wo)));');

-- The tech's phone knows a call is flat rate (so it shows the price book)
select from _patch_fn('tech_jobs()'::regprocedure,
  '''busy_ok'', w.busy_override_at is not null,',
  '''busy_ok'', w.busy_override_at is not null, ''flat'', _is_flat(w.id),');

grant execute on function save_price_item(uuid, text, numeric, text, text, text, boolean), import_price_book(jsonb),
  set_customer_price(uuid, uuid, numeric), set_billing_method(uuid, text), price_book(uuid, boolean),
  add_call_task(uuid, uuid, numeric), remove_call_task(uuid), call_tasks(uuid) to authenticated;
revoke execute on function save_price_item(uuid, text, numeric, text, text, text, boolean), import_price_book(jsonb),
  set_customer_price(uuid, uuid, numeric), set_billing_method(uuid, text), price_book(uuid, boolean),
  add_call_task(uuid, uuid, numeric), remove_call_task(uuid), call_tasks(uuid) from anon;
