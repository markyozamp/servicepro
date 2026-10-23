-- Stores can clear their own alerts:
--  * an unscheduled visitor: "Taken care of" (after calling their office, or sorting it out on site)
--  * a flagged call: "Got it" — the store has seen it; it stops counting toward the store's alerts
--    (the contractor still sees and resolves its own review items)
alter table site_visitors add column if not exists resolved_at timestamptz,
                          add column if not exists resolved_by uuid references profiles(id),
                          add column if not exists resolved_note text;
alter table guardrail_flags add column if not exists store_ack_at timestamptz,
                            add column if not exists store_ack_by uuid references profiles(id);

create or replace function store_resolve_visitor(p_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); x site_visitors;
begin
  select * into x from site_visitors where id = p_id;
  if x.id is null or not (is_customer_member(x.customer_id) and can_see_site(x.site_id)) then raise exception 'Not allowed.'; end if;
  update site_visitors set resolved_at = now(), resolved_by = m.id, resolved_note = nullif(trim(p_note), '') where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function store_resolve_visitor(uuid, text) from public, anon;
grant execute on function store_resolve_visitor(uuid, text) to authenticated;

create or replace function store_ack_flag(p_flag uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); g guardrail_flags; w work_orders;
begin
  select * into g from guardrail_flags where id = p_flag;
  select * into w from work_orders where id = g.work_order_id;
  if g.id is null or not g.visible_to_customer or not (is_customer_member(w.customer_id) and can_see_site(w.site_id)) then raise exception 'Not allowed.'; end if;
  update guardrail_flags set store_ack_at = now(), store_ack_by = m.id where id = p_flag;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function store_ack_flag(uuid) from public, anon;
grant execute on function store_ack_flag(uuid) to authenticated;

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
    ], null)) as x
    from sites s join profiles me on me.id = auth.uid() and me.active and me.customer_id = s.customer_id
    where profile_sees_site(me.id, s.id)
  ) t
$$;
revoke execute on function site_attention() from public, anon;
grant execute on function site_attention() to authenticated;
