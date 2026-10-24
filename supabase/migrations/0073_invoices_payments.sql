-- Base: Invoices & Payments, for the contractor who runs his business here (QuickBooks optional, never required).
--  * Owed to you: every unpaid invoice with its age (current / 1-30 / 31-60 / 61-90 / 90+ days past due), totals per customer.
--  * Payments: full or partial, date, how (check, cash, card, transfer, other), check / reference number; several per
--    invoice; the balance follows. A mistaken payment is voided (kept on the record), never erased.
--  * Terms: when invoices are due (default 30 days), per customer if needed.
--  * Reminders (if turned on): a friendly email at the first reminder day past due, a firmer one at the second, and a
--    "call them" alert to the office at the third. Customers with a login get them in their portal.
--  * Statement: everything open for one customer, printable, or emailed with a link to each invoice.
--  * Summary for any dates: billed, collected, still owed, sales tax; and a year-end download of invoices and payments.
-- "We bill and collect. Your accountant (or QuickBooks) keeps the books."

create table if not exists invoice_payments (
  id            uuid primary key default gen_random_uuid(),
  work_order_id uuid not null references work_orders(id) on delete cascade,
  contractor_id uuid not null,
  amount        numeric(12,2) not null check (amount > 0),
  paid_on       date not null default current_date,
  method        text not null default 'check' check (method in ('check', 'cash', 'card', 'transfer', 'other')),
  reference     text,
  note          text,
  recorded_by   uuid,
  created_at    timestamptz not null default now(),
  voided_at     timestamptz,
  voided_by     uuid,
  void_reason   text
);
create index if not exists invoice_payments_wo on invoice_payments (work_order_id);
create index if not exists invoice_payments_contractor on invoice_payments (contractor_id, paid_on);
alter table invoice_payments enable row level security;

alter table call_invoices add column if not exists amount_paid numeric(12,2) not null default 0;
alter table call_invoices add column if not exists reminders_sent int not null default 0;
alter table call_invoices add column if not exists last_reminder_at timestamptz;
alter table contractors add column if not exists payment_terms_days int not null default 30 check (payment_terms_days between 0 and 180);
alter table contractors add column if not exists remind_unpaid boolean not null default false;
alter table contractors add column if not exists remind_days int[] not null default '{1,15,30}';     -- days past due: friendly, firmer, call them
alter table customer_contractors add column if not exists terms_days int check (terms_days between 0 and 180);

-- Bills marked paid before payments existed count as paid in full
update call_invoices set amount_paid = total where paid_at is not null and amount_paid = 0;

create or replace function _inv_due(p_wo uuid) returns date
language sql stable security definer set search_path = public as $$
  select (i.entered_at at time zone coalesce(c.timezone, 'America/Chicago'))::date + coalesce(cc.terms_days, c.payment_terms_days, 30)
    from call_invoices i join work_orders w on w.id = i.work_order_id join contractors c on c.id = w.contractor_id
    left join customer_contractors cc on cc.contractor_id = w.contractor_id and cc.customer_id = w.customer_id
   where i.work_order_id = p_wo
$$;

-- Keep the invoice's paid amount (and paid date, once paid in full) in step with its payments
create or replace function _inv_settle(p_wo uuid) returns void
language plpgsql security definer set search_path = public as $$
declare paid numeric; last date; tot numeric;
begin
  select coalesce(sum(amount), 0), max(paid_on) into paid, last from invoice_payments where work_order_id = p_wo and voided_at is null;
  select total into tot from call_invoices where work_order_id = p_wo;
  update call_invoices set amount_paid = paid,
         paid_at = case when paid >= tot - 0.005 and tot > 0 then coalesce(paid_at, (last::timestamp + interval '12 hours') at time zone 'UTC') end,
         paid_note = case when paid >= tot - 0.005 and tot > 0 then paid_note end
   where work_order_id = p_wo;
end $$;

create or replace function _inv_office(p_wo uuid) returns work_orders
language plpgsql stable security definer set search_path = public as $$
declare w work_orders;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not is_contractor_office(w.contractor_id) then raise exception 'Not allowed.'; end if;
  if not exists (select 1 from call_invoices where work_order_id = p_wo) then raise exception 'There''s no invoice on this call yet.'; end if;
  return w;
end $$;

create or replace function record_payment(p_wo uuid, p_amount numeric, p_paid_on date default null, p_method text default 'check',
  p_reference text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _inv_office(p_wo); i call_invoices; bal numeric;
begin
  select * into i from call_invoices where work_order_id = p_wo for update;
  bal := i.total - i.amount_paid;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount paid.'; end if;
  if bal <= 0.005 then raise exception 'This invoice is already paid in full.'; end if;
  if p_amount > bal + 0.005 then raise exception 'That''s more than the $% still owed on this invoice.', trim_scale(bal); end if;
  if coalesce(p_method, 'check') not in ('check', 'cash', 'card', 'transfer', 'other') then raise exception 'Pick how it was paid.'; end if;
  if p_paid_on is not null and p_paid_on > current_date + 1 then raise exception 'The payment date can''t be in the future.'; end if;
  insert into invoice_payments (work_order_id, contractor_id, amount, paid_on, method, reference, note, recorded_by)
  values (p_wo, w.contractor_id, round(p_amount, 2), coalesce(p_paid_on, current_date), coalesce(p_method, 'check'),
          nullif(trim(p_reference), ''), nullif(trim(p_note), ''), auth.uid());
  perform _inv_settle(p_wo);
  select * into i from call_invoices where work_order_id = p_wo;
  return jsonb_build_object('ok', true, 'paid', i.amount_paid, 'balance', i.total - i.amount_paid, 'paid_in_full', i.paid_at is not null);
end $$;

create or replace function void_payment(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p invoice_payments; m profiles := me();
begin
  select * into p from invoice_payments where id = p_payment and voided_at is null;
  if p.id is null then raise exception 'That payment isn''t on file.'; end if;
  perform _inv_office(p.work_order_id);
  if not (m.is_org_admin or m.can_bill) then raise exception 'Only your owner or billing can void a payment.'; end if;
  if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'Say why (e.g. check bounced, entered twice).'; end if;
  update invoice_payments set voided_at = now(), voided_by = auth.uid(), void_reason = trim(p_reason) where id = p.id;
  perform _inv_settle(p.work_order_id);
  return jsonb_build_object('ok', true);
end $$;

-- The old one-tap "Mark paid" records a payment of the balance; "Not paid after all" voids the payments
create or replace function mark_bill_paid(p_wo uuid, p_paid boolean default true, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w work_orders := _inv_office(p_wo); i call_invoices;
begin
  select * into i from call_invoices where work_order_id = p_wo;
  if p_paid then
    if i.total - i.amount_paid > 0.005 then
      insert into invoice_payments (work_order_id, contractor_id, amount, paid_on, method, reference, recorded_by)
      values (p_wo, w.contractor_id, i.total - i.amount_paid, current_date, 'other', nullif(trim(p_note), ''), auth.uid());
    end if;
    perform _inv_settle(p_wo);
    update call_invoices set paid_note = coalesce(nullif(trim(p_note), ''), paid_note) where work_order_id = p_wo;
  else
    update invoice_payments set voided_at = now(), voided_by = auth.uid(), void_reason = 'Marked not paid' where work_order_id = p_wo and voided_at is null;
    perform _inv_settle(p_wo);
  end if;
  return jsonb_build_object('ok', true, 'paid', p_paid);
end $$;

create or replace function set_payment_terms(p_days int, p_remind boolean, p_remind_days int[] default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) or not is_contractor_office(m.contractor_id) then raise exception 'Only your owner or billing can change this.'; end if;
  if p_days is null or p_days < 0 or p_days > 180 then raise exception 'Terms are 0 to 180 days.'; end if;
  if p_remind_days is not null and (array_length(p_remind_days, 1) <> 3 or p_remind_days[1] < 0 or p_remind_days[2] <= p_remind_days[1] or p_remind_days[3] <= p_remind_days[2]) then
    raise exception 'Reminder days go up: first, second, then call them.';
  end if;
  update contractors set payment_terms_days = p_days, remind_unpaid = coalesce(p_remind, false), remind_days = coalesce(p_remind_days, remind_days)
   where id = m.contractor_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function set_customer_terms(p_customer uuid, p_days int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); n int;
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) or not is_contractor_office(m.contractor_id) then raise exception 'Only your owner or billing can change this.'; end if;
  if p_days is not null and (p_days < 0 or p_days > 180) then raise exception 'Terms are 0 to 180 days.'; end if;
  update customer_contractors set terms_days = p_days where contractor_id = m.contractor_id and customer_id = p_customer;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'That isn''t one of your customers.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Everything for the Invoices & Payments screen
create or replace function receivables() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); c contractors;
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Not allowed.'; end if;
  if not _is_base(m.contractor_id) then raise exception 'Invoices & Payments comes with Base.'; end if;
  select * into c from contractors where id = m.contractor_id;
  return (with inv as (
      select w.id work_order_id, w.number call_number, i.invoice_number, cu.id customer_id, cu.name customer, s.name site,
             (i.entered_at at time zone coalesce(c.timezone, 'America/Chicago'))::date as inv_date, _inv_due(w.id) due_on,
             i.total, i.amount_paid, i.total - i.amount_paid balance, i.status, i.emailed_to, i.reminders_sent, i.last_reminder_at,
             i.paid_at, w.mode, cu.email customer_email
        from call_invoices i join work_orders w on w.id = i.work_order_id join customers cu on cu.id = w.customer_id join sites s on s.id = w.site_id
       where w.contractor_id = m.contractor_id and i.entered_side = 'contractor')
    select jsonb_build_object(
      'can_settings', m.is_org_admin or m.can_bill,
      'terms_days', c.payment_terms_days, 'remind', c.remind_unpaid, 'remind_days', to_jsonb(c.remind_days),
      'open', (select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('days_late', greatest(0, current_date - x.due_on),
                 'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'amount', p.amount, 'paid_on', p.paid_on, 'method', p.method, 'reference', p.reference) order by p.paid_on), '[]')
                              from invoice_payments p where p.work_order_id = x.work_order_id and p.voided_at is null))
               order by x.due_on, x.inv_date), '[]') from inv x where x.balance > 0.005),
      'by_customer', (select coalesce(jsonb_agg(jsonb_build_object('customer_id', g.customer_id, 'customer', g.customer, 'owed', g.owed, 'invoices', g.n,
                        'oldest_days_late', g.late, 'email', g.email, 'terms_days', (select terms_days from customer_contractors where contractor_id = m.contractor_id and customer_id = g.customer_id))
                      order by g.owed desc), '[]')
                      from (select customer_id, customer, max(customer_email) email, sum(balance) owed, count(*) n, max(greatest(0, current_date - due_on)) late
                              from inv where balance > 0.005 group by 1, 2) g),
      'aging', (select jsonb_build_object(
                 'current', coalesce(sum(balance) filter (where current_date <= due_on), 0),
                 'd30', coalesce(sum(balance) filter (where current_date - due_on between 1 and 30), 0),
                 'd60', coalesce(sum(balance) filter (where current_date - due_on between 31 and 60), 0),
                 'd90', coalesce(sum(balance) filter (where current_date - due_on between 61 and 90), 0),
                 'over90', coalesce(sum(balance) filter (where current_date - due_on > 90), 0),
                 'total', coalesce(sum(balance), 0)) from inv where balance > 0.005),
      'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'work_order_id', p.work_order_id, 'invoice_number', x.invoice_number,
                     'customer', x.customer, 'amount', p.amount, 'paid_on', p.paid_on, 'method', p.method, 'reference', p.reference, 'note', p.note,
                     'voided_at', p.voided_at, 'void_reason', p.void_reason, 'by', (select full_name from profiles where id = p.recorded_by))
                   order by p.paid_on desc, p.created_at desc), '[]')
                   from invoice_payments p join inv x on x.work_order_id = p.work_order_id
                  where p.contractor_id = m.contractor_id and p.paid_on > current_date - 90)));
end $$;

-- Billed, collected and owed for any dates (and the rows for the year-end download)
create or replace function billing_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); c contractors;
begin
  if m.contractor_id is null or not (m.is_org_admin or m.can_bill) or not is_contractor_office(m.contractor_id) then raise exception 'Only your owner or billing can see this.'; end if;
  if not _is_base(m.contractor_id) then raise exception 'Invoices & Payments comes with Base.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Pick the dates.'; end if;
  select * into c from contractors where id = m.contractor_id;
  return jsonb_build_object('from', p_from, 'to', p_to,
    'billed', (select jsonb_build_object('count', count(*), 'total', coalesce(sum(i.total), 0), 'sales_tax', coalesce(sum(i.sales_tax), 0),
                 'before_tax', coalesce(sum(coalesce(i.subtotal, i.total)), 0))
               from call_invoices i join work_orders w on w.id = i.work_order_id
              where w.contractor_id = m.contractor_id and i.entered_side = 'contractor'
                and (i.entered_at at time zone coalesce(c.timezone, 'America/Chicago'))::date between p_from and p_to),
    'collected', (select jsonb_build_object('count', count(*), 'total', coalesce(sum(amount), 0),
                    'by_method', (select coalesce(jsonb_object_agg(method, t), '{}') from (select method, sum(amount) t from invoice_payments
                                   where contractor_id = m.contractor_id and voided_at is null and paid_on between p_from and p_to group by 1) q))
                  from invoice_payments where contractor_id = m.contractor_id and voided_at is null and paid_on between p_from and p_to),
    'owed_now', (select coalesce(sum(i.total - i.amount_paid), 0) from call_invoices i join work_orders w on w.id = i.work_order_id
                  where w.contractor_id = m.contractor_id and i.entered_side = 'contractor' and i.total - i.amount_paid > 0.005),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'date', (i.entered_at at time zone coalesce(c.timezone, 'America/Chicago'))::date,
                   'customer', cu.name, 'site', s.name, 'call_number', w.number, 'before_tax', coalesce(i.subtotal, i.total), 'sales_tax', coalesce(i.sales_tax, 0),
                   'total', i.total, 'paid', i.amount_paid, 'balance', i.total - i.amount_paid, 'due_on', _inv_due(w.id)) order by i.entered_at), '[]')
                 from call_invoices i join work_orders w on w.id = i.work_order_id join customers cu on cu.id = w.customer_id join sites s on s.id = w.site_id
                where w.contractor_id = m.contractor_id and i.entered_side = 'contractor'
                  and (i.entered_at at time zone coalesce(c.timezone, 'America/Chicago'))::date between p_from and p_to),
    'payment_rows', (select coalesce(jsonb_agg(jsonb_build_object('paid_on', p.paid_on, 'invoice_number', i.invoice_number, 'customer', cu.name,
                       'amount', p.amount, 'method', p.method, 'reference', p.reference, 'voided', p.voided_at is not null, 'void_reason', p.void_reason) order by p.paid_on), '[]')
                     from invoice_payments p join call_invoices i on i.work_order_id = p.work_order_id join work_orders w on w.id = p.work_order_id
                     join customers cu on cu.id = w.customer_id
                    where p.contractor_id = m.contractor_id and p.paid_on between p_from and p_to));
end $$;

-- One customer's statement: everything open
create or replace function customer_statement(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m profiles := me(); c contractors; cu customers;
begin
  if m.contractor_id is null or not is_contractor_office(m.contractor_id) then raise exception 'Not allowed.'; end if;
  if not exists (select 1 from customer_contractors where contractor_id = m.contractor_id and customer_id = p_customer) then raise exception 'That isn''t one of your customers.'; end if;
  select * into c from contractors where id = m.contractor_id;
  select * into cu from customers where id = p_customer;
  return jsonb_build_object(
    'contractor', jsonb_build_object('name', c.name, 'phone', c.phone, 'email', c.email, 'logo', c.logo_data),
    'customer', jsonb_build_object('id', cu.id, 'name', cu.name, 'contact', cu.contact_name, 'email', cu.email, 'phone', cu.phone,
                 'address', (select address from sites where customer_id = cu.id order by created_at limit 1)),
    'date', current_date,
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('work_order_id', w.id, 'invoice_number', i.invoice_number,
                   'date', (i.entered_at at time zone coalesce(c.timezone, 'America/Chicago'))::date, 'due_on', _inv_due(w.id), 'site', s.name,
                   'call_number', w.number, 'total', i.total, 'paid', i.amount_paid, 'balance', i.total - i.amount_paid,
                   'days_late', greatest(0, current_date - _inv_due(w.id))) order by i.entered_at), '[]')
                 from call_invoices i join work_orders w on w.id = i.work_order_id join sites s on s.id = w.site_id
                where w.contractor_id = m.contractor_id and w.customer_id = p_customer and i.entered_side = 'contractor' and i.total - i.amount_paid > 0.005));
end $$;

create or replace function email_statement(p_customer uuid, p_to text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st jsonb := customer_statement(p_customer); c contractors; to_ text; lines jsonb; tot numeric; x jsonb;
begin
  select * into c from contractors where id = (me()).contractor_id;
  to_ := lower(coalesce(nullif(trim(p_to), ''), st->'customer'->>'email'));
  if to_ is null then raise exception 'Enter an email for the customer.'; end if;
  if to_ !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right.'; end if;
  if jsonb_array_length(st->'invoices') = 0 then raise exception 'Nothing is owed right now.'; end if;
  select sum((v->>'balance')::numeric) into tot from jsonb_array_elements(st->'invoices') v;
  lines := jsonb_build_array(format('Hello%s,', coalesce(' ' || (st->'customer'->>'contact'), '')),
    format('Here is your statement from %s. Open balance: $%s.', c.name, trim_scale(tot)));
  for x in select * from jsonb_array_elements(st->'invoices') loop
    lines := lines || to_jsonb(format('Invoice %s (%s, %s): $%s due %s%s. View it: %s/i/%s', x->>'invoice_number', x->>'site', to_char((x->>'date')::date, 'Mon DD'),
      trim_scale((x->>'balance')::numeric), to_char((x->>'due_on')::date, 'Mon DD'),
      case when (x->>'days_late')::int > 0 then format(' (%s days past due)', x->>'days_late') else '' end,
      'https://servicecallproof.com', _bill_link((x->>'work_order_id')::uuid)));
  end loop;
  lines := lines || to_jsonb(format('Questions? Call %s%s, or reply to this email.', c.name, coalesce(' at ' || c.phone, '')));
  insert into email_queue (to_email, subject, lines, reply_to) values (to_, format('Statement from %s: $%s open', c.name, trim_scale(tot)), lines, c.email);
  return jsonb_build_object('ok', true, 'emailed_to', to_, 'total', tot);
end $$;

-- Daily: payment reminders for contractors who turned them on
create or replace function payment_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; stage int; t uuid; late int; msg text;
begin
  for r in select i.work_order_id, i.invoice_number, i.total - i.amount_paid bal, i.reminders_sent, i.emailed_to, w.number, w.customer_id, w.contractor_id,
                  c.name cname, c.phone cphone, c.email cemail, c.remind_days rd, cu.contact_name, cu.email cu_email, cu.name cu_name, _inv_due(w.id) due
             from call_invoices i join work_orders w on w.id = i.work_order_id join contractors c on c.id = w.contractor_id join customers cu on cu.id = w.customer_id
            where c.remind_unpaid and c.level <> 'verify' and i.entered_side = 'contractor' and i.status <> 'disputed'
              and i.total - i.amount_paid > 0.005 and i.reminders_sent < 3
              and (cu.name not like '%(demo)' or current_setting('app.watch_demo', true) = 'on') loop
    late := current_date - r.due;
    stage := case when late >= r.rd[3] then 3 when late >= r.rd[2] then 2 when late >= r.rd[1] then 1 else 0 end;
    if stage <= r.reminders_sent then continue; end if;
    if stage = 3 then
      perform _notify(p.id, r.work_order_id, 'billing_overdue', format('Call them: invoice %s (%s) is %s days past due, $%s still owed. Reminders were sent.',
        r.invoice_number, r.cu_name, late, trim_scale(r.bal)), 'collect:' || r.work_order_id)
        from profiles p where p.contractor_id = r.contractor_id and p.active and (p.is_org_admin or p.can_bill);
    else
      msg := case when stage = 1 then format('A friendly reminder: invoice %s from %s for $%s was due %s.', r.invoice_number, r.cname, trim_scale(r.bal), to_char(r.due, 'Mon DD'))
                  else format('Invoice %s from %s for $%s is now %s days past due. Please arrange payment, or call us if there''s a problem with the bill.', r.invoice_number, r.cname, trim_scale(r.bal), late) end;
      if _customer_has_logins(r.customer_id) then
        perform _notify_customer(r.work_order_id, 'billing_overdue', msg, 'remind' || stage || ':' || r.work_order_id);
      elsif coalesce(r.emailed_to, r.cu_email) is not null then
        t := _bill_link(r.work_order_id);
        insert into email_queue (to_email, subject, lines, button, reply_to)
        values (coalesce(r.emailed_to, r.cu_email), case when stage = 1 then format('Reminder: invoice %s from %s', r.invoice_number, r.cname)
                                                         else format('Past due: invoice %s from %s', r.invoice_number, r.cname) end,
                jsonb_build_array(format('Hello%s,', coalesce(' ' || r.contact_name, '')), msg,
                  'If you''ve already paid, thank you, and please ignore this.', format('Questions? Call %s%s.', r.cname, coalesce(' at ' || r.cphone, ''))),
                jsonb_build_object('label', 'View the invoice', 'path', '/i/' || t), r.cemail);
      end if;
    end if;
    update call_invoices set reminders_sent = stage, last_reminder_at = now() where work_order_id = r.work_order_id;
    n := n + 1;
  end loop;
  return n;
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-pay-reminders', '17 15 * * *', 'select public.payment_reminders()');   -- mid-morning Central
  end if;
end $$;

-- The customer's copy shows what's been paid and what's left
select from _patch_fn('bill_public(uuid)'::regprocedure,
  '''flat'', i.flat, ''paid'', i.paid_at is not null, ''paid_at'', i.paid_at,',
  '''flat'', i.flat, ''paid'', i.paid_at is not null, ''paid_at'', i.paid_at, ''amount_paid'', i.amount_paid, ''balance'', i.total - i.amount_paid,
    ''due_on'', _inv_due(w.id),');
select from _patch_fn('bill_view(uuid)'::regprocedure,
  '''paid_at'', i.paid_at, ''emailed_to'', i.emailed_to)',
  '''paid_at'', i.paid_at, ''emailed_to'', i.emailed_to, ''amount_paid'', i.amount_paid, ''balance'', i.total - i.amount_paid,
    ''due_on'', case when i.work_order_id is not null then _inv_due(p_wo) end)');
select from _patch_fn('_invoice_check(uuid)'::regprocedure,
  '''paid_at'', i.paid_at,',
  '''paid_at'', i.paid_at, ''amount_paid'', i.amount_paid,');

grant execute on function record_payment(uuid, numeric, date, text, text, text), void_payment(uuid, text), set_payment_terms(int, boolean, int[]),
  set_customer_terms(uuid, int), receivables(), billing_summary(date, date), customer_statement(uuid), email_statement(uuid, text) to authenticated;
revoke execute on function record_payment(uuid, numeric, date, text, text, text), void_payment(uuid, text), set_payment_terms(int, boolean, int[]),
  set_customer_terms(uuid, int), receivables(), billing_summary(date, date), customer_statement(uuid), email_statement(uuid, text) from anon;
revoke execute on function _inv_settle(uuid), _inv_office(uuid), payment_reminders() from public, anon, authenticated;
