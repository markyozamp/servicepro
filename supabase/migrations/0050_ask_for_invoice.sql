-- A store can ask a contractor for a late invoice from the call: the contractor's office gets it by email/phone alert,
-- the call shows when it was asked, and if nothing comes within a day, both sides are reminded (once a day).
alter table work_orders add column if not exists bill_requested_at    timestamptz,
                        add column if not exists bill_requested_by    uuid references profiles(id),
                        add column if not exists bill_request_count   int not null default 0;

create or replace function store_request_bill(p_wo uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; cname text; kname text;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not (is_customer_member(w.customer_id) and can_see_site(w.site_id)) then raise exception 'Not allowed.'; end if;
  if w.status <> 'completed' then raise exception 'The invoice for this call has already come in.'; end if;
  if w.bill_requested_at > now() - interval '4 hours' then
    raise exception 'You already asked at %. They''ve been told; if the invoice doesn''t come within a day, you''ll both be reminded.',
      to_char(w.bill_requested_at at time zone coalesce((select timezone from sites where id = w.site_id), 'America/Chicago'), 'FMHH12:MI AM');
  end if;
  select name into cname from customers where id = w.customer_id;
  select name into kname from contractors where id = w.contractor_id;
  perform _allow_internal(true);
  update work_orders set bill_requested_at = now(), bill_requested_by = m.id, bill_request_count = bill_request_count + 1 where id = w.id;
  perform _end_internal();
  perform _notify_office(w.id, 'billing_overdue', format('%s is asking for your invoice for call #%s (%s), completed %s. It was due to them %s. Please enter it in Service Call Proof today.',
    cname, w.number, _po(w), to_char(w.completed_at, 'Mon DD'), to_char(w.invoice_due_at, 'Mon DD')), 'billreq:' || w.id || ':' || to_char(now(), 'YYYYMMDDHH24'));
  return jsonb_build_object('ok', true, 'asked_at', now(), 'contractor', kname);
end $$;
revoke execute on function store_request_bill(uuid) from public, anon;
grant execute on function store_request_bill(uuid) to authenticated;

-- Hourly: a day after asking with still no invoice, remind both sides (once a day)
create or replace function bill_request_watch() returns int
language plpgsql security definer set search_path = public as $$
declare w work_orders; n int := 0; kname text; cname text;
begin
  for w in select * from work_orders where status = 'completed' and bill_requested_at is not null and bill_requested_at < now() - interval '24 hours' loop
    select name into kname from contractors where id = w.contractor_id;
    select name into cname from customers where id = w.customer_id;
    perform _notify_customer(w.id, 'billing_overdue', format('Still no invoice for call #%s: you asked %s on %s and they haven''t sent it yet. Call them from the call screen.',
      w.number, kname, to_char(w.bill_requested_at, 'Mon DD')), 'billreq_late:' || w.id || ':' || to_char(now(), 'YYYYMMDD'));
    perform _notify_office(w.id, 'billing_overdue', format('Reminder: %s asked for your invoice for call #%s on %s and still hasn''t received it.',
      cname, w.number, to_char(w.bill_requested_at, 'Mon DD')), 'billreq_late:' || w.id || ':' || to_char(now(), 'YYYYMMDD'));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function bill_request_watch() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-bill-requests', '22 * * * *', 'select public.bill_request_watch()');
  end if;
end $$;
