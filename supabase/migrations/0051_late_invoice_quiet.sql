-- Once the store asks for a late invoice (by email/alert or by phone), the late-bill alert goes quiet.
-- It comes back only if 2 days pass with still no invoice; then both sides are reminded (once a day).
alter table work_orders add column if not exists bill_request_how text check (bill_request_how in ('email','call'));

create or replace function store_followup_bill(p_wo uuid, p_how text default 'email') returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; cname text; kname text; how text := case when p_how = 'call' then 'call' else 'email' end;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null or not (is_customer_member(w.customer_id) and can_see_site(w.site_id)) then raise exception 'Not allowed.'; end if;
  if w.status <> 'completed' then raise exception 'The invoice for this call has already come in.'; end if;
  if how = 'email' and w.bill_request_how = 'email' and w.bill_requested_at > now() - interval '4 hours' then
    raise exception 'You already asked at %. They''ve been told; if the invoice doesn''t come within 2 days, you''ll both be reminded.',
      to_char(w.bill_requested_at at time zone coalesce((select timezone from sites where id = w.site_id), 'America/Chicago'), 'FMHH12:MI AM');
  end if;
  select name into cname from customers where id = w.customer_id;
  select name into kname from contractors where id = w.contractor_id;
  perform _allow_internal(true);
  update work_orders set bill_requested_at = now(), bill_requested_by = m.id, bill_request_count = bill_request_count + 1, bill_request_how = how where id = w.id;
  perform _end_internal();
  perform _notify_office(w.id, 'billing_overdue', case when how = 'email'
      then format('%s is asking for your invoice for call #%s (%s), completed %s. It was due to them %s. Please enter it in Service Call Proof today.',
        cname, w.number, _po(w), to_char(w.completed_at, 'Mon DD'), to_char(w.invoice_due_at, 'Mon DD'))
      else format('%s (%s) called you about the late invoice for call #%s (%s). Please enter it in Service Call Proof.',
        m.full_name, cname, w.number, _po(w)) end,
    'billreq:' || w.id || ':' || how || ':' || to_char(now(), 'YYYYMMDDHH24'));
  return jsonb_build_object('ok', true, 'asked_at', now(), 'how', how, 'contractor', kname);
end $$;
revoke execute on function store_followup_bill(uuid, text) from public, anon;
grant execute on function store_followup_bill(uuid, text) to authenticated;

-- The old one-argument version keeps working (same as asking by email)
create or replace function store_request_bill(p_wo uuid) returns jsonb
language sql security definer set search_path = public as $$ select store_followup_bill(p_wo, 'email') $$;

-- Reminder after 2 days (was 1)
create or replace function bill_request_watch() returns int
language plpgsql security definer set search_path = public as $$
declare w work_orders; n int := 0; kname text; cname text;
begin
  for w in select * from work_orders where status = 'completed' and bill_requested_at is not null and bill_requested_at < now() - interval '2 days' loop
    select name into kname from contractors where id = w.contractor_id;
    select name into cname from customers where id = w.customer_id;
    perform _notify_customer(w.id, 'billing_overdue', format('Still no invoice for call #%s: you contacted %s on %s and they haven''t sent it yet.',
      w.number, kname, to_char(w.bill_requested_at, 'Mon DD')), 'billreq_late:' || w.id || ':' || to_char(now(), 'YYYYMMDD'));
    perform _notify_office(w.id, 'billing_overdue', format('Reminder: %s contacted you about your invoice for call #%s on %s and still hasn''t received it.',
      cname, w.number, to_char(w.bill_requested_at, 'Mon DD')), 'billreq_late:' || w.id || ':' || to_char(now(), 'YYYYMMDD'));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function bill_request_watch() from public, anon, authenticated;

-- Store attention: a late bill the store has followed up on in the last 2 days doesn't count; the late-bill flag
-- itself isn't counted twice ("A bill is overdue" already covers it).
create or replace function site_attention() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) from (
    select jsonb_build_object('site_id', s.id, 'name', s.name, 'reasons', array_remove(array[
      case when exists (select 1 from visits v join work_orders w on w.id = v.work_order_id where w.site_id = s.id and v.status = 'on_site'
             and v.checkin_required and v.checkin_at is null) then 'A technician is waiting for the check-in code' end,
      case when exists (select 1 from po_lines l join work_orders w on w.id = l.work_order_id where w.site_id = s.id and l.status = 'pending')
           then 'Waiting for your approval' end,
      case when exists (select 1 from work_orders w where w.site_id = s.id and w.status = 'completed' and w.invoice_due_at < now()
             and (w.bill_requested_at is null or w.bill_requested_at < now() - interval '2 days'))
           then 'A contractor''s invoice is late' end,
      case when exists (select 1 from visits v join work_orders w on w.id = v.work_order_id where w.site_id = s.id and v.status = 'assigned'
             and v.missed_alert_at is not null) then 'A technician missed their window' end,
      case when exists (select 1 from site_visitors sv where sv.site_id = s.id and sv.recorded_at > now() - interval '24 hours')
           then 'Unscheduled visitor today' end,
      case when exists (select 1 from guardrail_flags g join work_orders w on w.id = g.work_order_id where w.site_id = s.id
             and g.resolved_at is null and g.visible_to_customer and g.flag <> 'billing_late') then 'A call is flagged for review' end
    ], null)) as x
    from sites s join profiles me on me.id = auth.uid() and me.active and me.customer_id = s.customer_id
    where profile_sees_site(me.id, s.id)
  ) t
$$;
revoke execute on function site_attention() from public, anon;
grant execute on function site_attention() to authenticated;
