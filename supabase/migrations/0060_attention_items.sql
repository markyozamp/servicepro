-- The location menu lists every alert, one line each, so a manager can click through them in order.
-- site_attention() keeps 'reasons' (short summary) and adds 'items': one entry per thing to deal with, with where it is on the page.
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
      case when exists (select 1 from site_visitors sv where sv.site_id = s.id and sv.recorded_at > now() - interval '24 hours' and sv.resolved_at is null)
           then 'Unscheduled visitor today' end,
      case when exists (select 1 from guardrail_flags g join work_orders w on w.id = g.work_order_id where w.site_id = s.id
             and g.resolved_at is null and g.visible_to_customer and g.flag <> 'billing_late' and g.store_ack_at is null) then 'A call is flagged for review' end
    ], null),
    'items', (select coalesce(jsonb_agg(i order by i.ord, i.at), '[]'::jsonb) from (
      -- technician at the door
      select 1 ord, v.arrived_at at, 'door' kind, 'door-' || v.id target,
             format('%s is at the door for call #%s: give the check-in code', p.full_name, w.number) label
        from visits v join work_orders w on w.id = v.work_order_id join profiles p on p.id = v.technician_id
       where w.site_id = s.id and v.status = 'on_site' and v.checkin_required and v.checkin_at is null
      union all
      -- crew size to confirm
      select 2, v.crew_set_at, 'crew', 'crew-' || v.id,
             format('Confirm %s''s crew on call #%s (%s)', p.full_name, w.number, case v.crew_helpers when 1 then '1 helper' else v.crew_helpers || ' helpers' end)
        from visits v join work_orders w on w.id = v.work_order_id join profiles p on p.id = v.technician_id
       where w.site_id = s.id and v.status = 'on_site' and v.crew_set_at is not null and v.crew_confirmed is null and v.crew_helpers > 0
      union all
      -- approvals
      select 3, l.requested_at, 'approval', 'appr-' || l.id,
             format('Approve $%s more on call #%s: %s', trim_scale(l.amount), w.number, left(l.description, 60))
        from po_lines l join work_orders w on w.id = l.work_order_id
       where w.site_id = s.id and l.status = 'pending'
      union all
      -- calls a contractor entered that need confirming
      select 4, w.created_at, 'confirm', 'confirm-' || w.id,
             format('Confirm call #%s that %s entered', w.number, (select name from contractors where id = w.contractor_id))
        from work_orders w
       where w.site_id = s.id and w.source = 'contractor' and w.mode = 'verify' and w.store_confirmed_at is null and w.status <> 'cancelled'
      union all
      -- not accepted in time / declined
      select 5, w.accept_due_at, 'notaccepted', 'nacc-' || w.id,
             format('Call #%s: %s %s', w.number, (select name from contractors where id = w.contractor_id),
                    case when w.declined_at is not null then 'can''t take it' else 'hasn''t accepted it' end)
        from work_orders w
       where w.site_id = s.id and w.mode = 'verify' and w.status = 'created'
         and ((w.accepted_at is null and w.accept_due_at < now()) or w.declined_at is not null)
      union all
      -- missed arrival window
      select 6, v.missed_alert_at, 'missed', 'presence',
             format('%s missed their window for call #%s', p.full_name, w.number)
        from visits v join work_orders w on w.id = v.work_order_id join profiles p on p.id = v.technician_id
       where w.site_id = s.id and v.status = 'assigned' and v.missed_alert_at is not null
      union all
      -- unscheduled visitors
      select 7, sv.recorded_at, 'visitor', 'visitor-' || sv.id,
             format('Unscheduled visitor: %s%s', coalesce(sv.visitor_name, 'someone'), coalesce(' (' || sv.company || ')', ''))
        from site_visitors sv
       where sv.site_id = s.id and sv.recorded_at > now() - interval '24 hours' and sv.resolved_at is null
      union all
      -- flagged calls (one line per call)
      select 8, min(g.triggered_at), 'flag', 'flag-' || w.id,
             format('Call #%s is flagged for review (%s)', w.number, count(*) || case when count(*) = 1 then ' item' else ' items' end)
        from guardrail_flags g join work_orders w on w.id = g.work_order_id
       where w.site_id = s.id and g.resolved_at is null and g.visible_to_customer and g.flag <> 'billing_late' and g.store_ack_at is null
       group by w.id, w.number
      union all
      -- late invoices
      select 9, w.invoice_due_at, 'late', 'late-' || w.id,
             format('Invoice not received: call #%s (%s)', w.number, (select name from contractors where id = w.contractor_id))
        from work_orders w
       where w.site_id = s.id and w.status = 'completed' and w.invoice_due_at < now()
         and (w.bill_requested_at is null or w.bill_requested_at < now() - interval '2 days')
    ) i)) as x
    from sites s join profiles me on me.id = auth.uid() and me.active and me.customer_id = s.customer_id
    where profile_sees_site(me.id, s.id)
  ) t
$$;
