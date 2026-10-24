-- Base: all your own customers, and bills to any customer.
-- 1) A Base contractor adds their own customers (businesses or homeowners), with as many locations as they need.
--    These customers don't use Service Call Proof themselves; the contractor keeps their details.
-- 2) The built bill works on these calls too. Sending it finishes the call as invoiced and emails the customer a link
--    to their bill (no login): the itemized bill with the verified visits, to print or save as a PDF.
--    Customers who do have logins get it in their portal as before.
-- 3) The office marks bills paid, so what's still owed is easy to see. (Paying online comes with Stripe.)

alter table customers add column if not exists managed_by uuid;        -- the contractor who added and keeps this customer
alter table customers add column if not exists contact_name text;
alter table call_invoices add column if not exists paid_at timestamptz;
alter table call_invoices add column if not exists paid_note text;
alter table call_invoices add column if not exists emailed_to text;
alter table call_invoices add column if not exists emailed_at timestamptz;

create or replace function _my_customer(p_customer uuid) returns customers
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); c customers;
begin
  select * into c from customers where id = p_customer;
  if c.id is null or m.contractor_id is null or c.managed_by is distinct from m.contractor_id or not is_contractor_dispatcher(m.contractor_id) then
    raise exception 'Only the contractor who added this customer can change it.';
  end if;
  return c;
end $$;

-- Office: add a customer of your own (business or homeowner) with their first location
create or replace function add_my_customer(p_name text, p_business boolean, p_address text, p_contact text default null,
  p_phone text default null, p_email text default null, p_site_name text default null, p_zip text default null,
  p_access_notes text default null, p_lat double precision default null, p_lon double precision default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cu customers; s sites; tz text;
begin
  if m.contractor_id is null or not is_contractor_dispatcher(m.contractor_id) then raise exception 'Only your office can add customers.'; end if;
  if not _is_base(m.contractor_id) then raise exception 'Adding your own customers comes with Base.'; end if;
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_address), '') = '' then raise exception 'Name and address are required.'; end if;
  if nullif(trim(p_email), '') is not null and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right.'; end if;
  select timezone into tz from contractors where id = m.contractor_id;
  insert into customers (name, kind, phone, email, contact_name, managed_by)
  values (trim(p_name), case when coalesce(p_business, true) then 'commercial' else 'residential' end::customer_kind,
          nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''), nullif(trim(p_contact), ''), m.contractor_id)
  returning * into cu;
  insert into customer_contractors (contractor_id, customer_id) values (m.contractor_id, cu.id);
  insert into sites (customer_id, name, address, zip, access_notes, timezone, lat, lon)
  values (cu.id, coalesce(nullif(trim(p_site_name), ''), case when coalesce(p_business, true) then 'Main location' else 'Home' end),
          trim(p_address), nullif(trim(p_zip), ''), nullif(trim(p_access_notes), ''), coalesce(tz, 'America/Chicago'), p_lat, p_lon)
  returning * into s;
  return jsonb_build_object('customer_id', cu.id, 'site_id', s.id);
end $$;

create or replace function add_my_customer_site(p_customer uuid, p_name text, p_address text, p_zip text default null,
  p_access_notes text default null, p_lat double precision default null, p_lon double precision default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c customers := _my_customer(p_customer); s sites;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_address), '') = '' then raise exception 'Name and address are required.'; end if;
  insert into sites (customer_id, name, address, zip, access_notes, timezone, lat, lon)
  values (c.id, trim(p_name), trim(p_address), nullif(trim(p_zip), ''), nullif(trim(p_access_notes), ''),
          coalesce((select timezone from contractors where id = c.managed_by), 'America/Chicago'), p_lat, p_lon)
  returning * into s;
  return jsonb_build_object('site_id', s.id);
end $$;

create or replace function update_my_customer(p_customer uuid, p_name text, p_contact text, p_phone text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c customers := _my_customer(p_customer);
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'The customer needs a name.'; end if;
  if nullif(trim(p_email), '') is not null and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right.'; end if;
  update customers set name = trim(p_name), contact_name = nullif(trim(p_contact), ''), phone = nullif(trim(p_phone), ''),
         email = nullif(lower(trim(p_email)), '') where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

-- The customer list knows which customers are the contractor's own (to edit them and add locations)
select from _patch_fn('contractor_book()'::regprocedure,
  '''customer_id'', c.id, ''name'', c.name, ''kind'', c.kind,',
  '''customer_id'', c.id, ''name'', c.name, ''kind'', c.kind, ''managed'', c.managed_by = m.contractor_id, ''contact_name'', c.contact_name,');

-- ============ Emails to people without a login ============
create table if not exists email_queue (
  id         uuid primary key default gen_random_uuid(),
  to_email   text not null,
  subject    text not null,
  lines      jsonb not null default '[]',
  button     jsonb,
  reply_to   text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
alter table email_queue enable row level security;

create or replace function email_take(p_key text, p_limit int default 50) returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb;
begin
  if p_key is null or p_key is distinct from (select value from app_secrets where name = 'outbox') then raise exception 'Not allowed.'; end if;
  with picked as (select id from email_queue where sent_at is null and created_at > now() - interval '2 days'
                   order by created_at limit least(greatest(p_limit, 1), 100) for update skip locked),
       sent as (update email_queue e set sent_at = now() from picked where e.id = picked.id returning e.*)
  select coalesce(jsonb_agg(jsonb_build_object('to', to_email, 'subject', subject, 'lines', lines, 'button', button, 'reply_to', reply_to)), '[]')
    into out from sent;
  return out;
end $$;
revoke execute on function email_take(text, int) from public, anon, authenticated;
grant execute on function email_take(text, int) to anon;    -- the outbox route calls it with the key

-- A no-login link to one bill
create table if not exists bill_links (
  token         uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references work_orders(id) on delete cascade,
  created_at    timestamptz not null default now(),
  viewed_at     timestamptz
);
create index if not exists bill_links_wo on bill_links (work_order_id);
alter table bill_links enable row level security;

create or replace function _bill_link(p_wo uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  select token into t from bill_links where work_order_id = p_wo order by created_at desc limit 1;
  if t is null then insert into bill_links (work_order_id) values (p_wo) returning token into t; end if;
  return t;
end $$;

-- Email the bill to a customer (their email, or one the office types)
create or replace function _email_bill(p_wo uuid, p_to text) returns text
language plpgsql security definer set search_path = public as $$
declare w work_orders; i call_invoices; c contractors; cu customers; t uuid; site text;
begin
  select * into w from work_orders where id = p_wo;
  select * into i from call_invoices where work_order_id = p_wo;
  select * into c from contractors where id = w.contractor_id;
  select * into cu from customers where id = w.customer_id;
  if coalesce(trim(p_to), '') = '' then return null; end if;
  t := _bill_link(p_wo);
  site := (select name from sites where id = w.site_id);
  insert into email_queue (to_email, subject, lines, button, reply_to)
  values (lower(trim(p_to)), format('Invoice %s from %s: $%s', i.invoice_number, c.name, trim_scale(i.total)),
          jsonb_build_array(format('Hello%s,', coalesce(' ' || cu.contact_name, '')),
            format('Here is invoice %s from %s for the work at %s (call #%s): $%s.', i.invoice_number, c.name, site, w.number, trim_scale(i.total)),
            'The bill shows each line and when the technician was on site. You can print it or save it as a PDF.',
            format('Questions? Call %s%s.', c.name, coalesce(' at ' || c.phone, ''))),
          jsonb_build_object('label', 'View your invoice', 'path', '/i/' || t), c.email);
  update call_invoices set emailed_to = lower(trim(p_to)), emailed_at = now() where work_order_id = p_wo;
  return lower(trim(p_to));
end $$;
revoke execute on function _email_bill(uuid, text) from public, anon, authenticated;
revoke execute on function _bill_link(uuid) from public, anon, authenticated;

-- ============ Sending a built bill on your own customer's call ============
create or replace function _send_own_bill(p_wo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; d bill_drafts; s jsonb := _bill_summary(p_wo); logins boolean; sent_to text;
begin
  select * into w from work_orders where id = p_wo for update;
  select * into d from bill_drafts where work_order_id = p_wo;
  if not w.invoice_ready and w.status = 'completed' then raise exception 'Resolve the review items on the call first.'; end if;
  if exists (select 1 from call_invoices where work_order_id = p_wo and paid_at is not null) then raise exception 'This bill is already marked paid.'; end if;
  insert into call_invoices (work_order_id, invoice_number, po_number, total, hours_billed, entered_side, entered_by, entered_at, status,
                             review_note, lines, built, flat, agreed_hours, agreed_cap)
  values (p_wo, trim(d.invoice_number), _po(w), (s->>'total')::numeric, (s->>'labor_h')::numeric, 'contractor', m.id, now(), 'approved',
          'Sent to the customer', d.lines, true, _is_flat(p_wo), true, true)
  on conflict (work_order_id) do update set invoice_number = excluded.invoice_number, total = excluded.total, hours_billed = excluded.hours_billed,
    entered_by = excluded.entered_by, entered_at = now(), status = 'approved', review_note = excluded.review_note, lines = excluded.lines,
    built = true, flat = excluded.flat;
  update guardrail_flags set resolved_at = now(), resolution_note = 'Invoice sent'
   where work_order_id = p_wo and flag = 'billing_late' and resolved_at is null;
  perform _allow_internal(true);
  update work_orders set status = 'invoiced', qbo_invoice_id = trim(d.invoice_number), invoiced_at = coalesce(invoiced_at, now()),
         total_cost = (s->>'total')::numeric where id = p_wo returning * into w;
  perform _end_internal();
  logins := _customer_has_logins(w.customer_id);
  if logins then
    perform _notify_customer(p_wo, 'completed', format('Invoice %s for call #%s: $%s. Open the call to see the itemized bill.',
      trim(d.invoice_number), w.number, trim_scale((s->>'total')::numeric)));
  else
    sent_to := _email_bill(p_wo, (select email from customers where id = w.customer_id));
  end if;
  return jsonb_build_object('ok', true, 'emailed_to', sent_to, 'portal', logins);
end $$;
revoke execute on function _send_own_bill(uuid) from public, anon, authenticated;

-- send_built_bill: calls on the contractor's own (non Time Verify) customers go this way
select from _patch_fn('send_built_bill(uuid,text,boolean)'::regprocedure,
  '  if (s->>''total'')::numeric <= 0 then raise exception ''The bill comes to $0.''; end if;',
  '  if (s->>''total'')::numeric <= 0 then raise exception ''The bill comes to $0.''; end if;
  if w.mode <> ''verify'' then
    perform _send_own_bill(p_wo);
    update bill_drafts set sent_at = now() where work_order_id = p_wo;
    perform set_config(''app.demo_guard_off'', ''on'', true);
    update contractors set next_invoice_no = coalesce(next_invoice_no, 1001) + 1
     where id = w.contractor_id and coalesce(invoice_prefix, '''') || coalesce(next_invoice_no, 1001) = trim(d.invoice_number);
    perform set_config(''app.demo_guard_off'', ''off'', true);
    return _invoice_check(p_wo) || jsonb_build_object(''emailed_to'', (select emailed_to from call_invoices where work_order_id = p_wo));
  end if;');

-- Office: email the bill again (or to another address)
create or replace function email_bill(p_wo uuid, p_to text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders; to_ text;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
  if not exists (select 1 from call_invoices where work_order_id = p_wo) then raise exception 'Send the bill first.'; end if;
  to_ := coalesce(nullif(trim(p_to), ''), (select email from customers where id = w.customer_id));
  if to_ is null then raise exception 'Enter an email for the customer.'; end if;
  if to_ !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right.'; end if;
  return jsonb_build_object('emailed_to', _email_bill(p_wo, to_));
end $$;

-- Office: paid (or not paid after all)
create or replace function mark_bill_paid(p_wo uuid, p_paid boolean default true, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
  update call_invoices set paid_at = case when p_paid then now() end, paid_note = case when p_paid then nullif(trim(p_note), '') end
   where work_order_id = p_wo;
  if not found then raise exception 'There''s no bill on this call yet.'; end if;
  return jsonb_build_object('ok', true, 'paid', p_paid);
end $$;

-- The customer's copy, from the emailed link (no login)
create or replace function bill_public(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l bill_links; w work_orders; i call_invoices; c contractors; v jsonb;
begin
  select * into l from bill_links where token = p_token;
  if l.token is null then return null; end if;
  select * into w from work_orders where id = l.work_order_id;
  select * into i from call_invoices where work_order_id = w.id;
  if i.work_order_id is null then return null; end if;
  update bill_links set viewed_at = coalesce(viewed_at, now()) where token = p_token;
  select * into c from contractors where id = w.contractor_id;
  v := _verified(w.id);
  return jsonb_build_object(
    'contractor', jsonb_build_object('name', c.name, 'phone', c.phone, 'email', c.email, 'logo', c.logo_data),
    'customer', (select name from customers where id = w.customer_id),
    'site', (select jsonb_build_object('name', s.name, 'address', s.address) from sites s where s.id = w.site_id),
    'call_number', w.number, 'po', i.po_number, 'unit', w.unit, 'problem', w.issue_description, 'summary', w.work_summary,
    'invoice_number', i.invoice_number, 'date', i.entered_at, 'lines', i.lines, 'built', i.built, 'total', i.total,
    'flat', i.flat, 'paid', i.paid_at is not null, 'paid_at', i.paid_at,
    'visits', (select coalesce(jsonb_agg(jsonb_build_object('tech', x->>'tech', 'arrived', x->>'arrived_at', 'left', x->>'left_at',
                  'onsite_min', x->>'onsite_min', 'verified', coalesce((x->>'checkin_verified')::boolean, false), 'helpers', x->>'helpers')), '[]')
               from jsonb_array_elements(v->'visits') x));
end $$;
grant execute on function bill_public(uuid) to anon, authenticated;

-- The bill check and the printable bill show paid / emailed
select from _patch_fn('_invoice_check(uuid)'::regprocedure,
  '''built'', i.built, ''flat'', i.flat)',
  '''built'', i.built, ''flat'', i.flat, ''paid_at'', i.paid_at, ''emailed_to'', i.emailed_to, ''emailed_at'', i.emailed_at)');
select from _patch_fn('bill_view(uuid)'::regprocedure,
  '''flat'', coalesce(i.flat, _is_flat(p_wo)));',
  '''flat'', coalesce(i.flat, _is_flat(p_wo)), ''paid_at'', i.paid_at, ''emailed_to'', i.emailed_to);');

-- invoice_check is used on own-customer calls too (it reads the verified record and the invoice)
grant execute on function add_my_customer(text, boolean, text, text, text, text, text, text, text, double precision, double precision),
  add_my_customer_site(uuid, text, text, text, text, double precision, double precision), update_my_customer(uuid, text, text, text, text),
  email_bill(uuid, text), mark_bill_paid(uuid, boolean, text) to authenticated;
