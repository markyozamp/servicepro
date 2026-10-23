-- The light bill (Time Verify): the contractor agrees to the verified hours and that the bill stays within
-- the PO limit plus approved additions, then gives his own invoice number and total. Parts aren't itemized:
-- they live under the PO (more money goes through "Request approval for more").
-- Stores approve bills by default; a store can switch on auto-approve for bills that match exactly.

alter table customers add column if not exists auto_approve_bills boolean not null default false;
alter table call_invoices add column if not exists agreed_hours boolean,       -- null = entered by the store / old form
                          add column if not exists agreed_cap boolean,
                          add column if not exists auto_approved boolean not null default false;

create or replace function set_auto_approve_bills(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'company') then raise exception 'You don''t have permission to change company settings.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  perform _allow_internal(true);
  update customers set auto_approve_bills = coalesce(p_on, false) where id = m.customer_id;
  perform _end_internal();
  return jsonb_build_object('ok', true, 'on', coalesce(p_on, false));
end $$;
revoke execute on function set_auto_approve_bills(boolean) from public, anon;
grant execute on function set_auto_approve_bills(boolean) to authenticated;

-- Bill check now knows the ceiling (PO limit + approved additions), the number of trips and how the bill was agreed
create or replace function _invoice_check(p_wo uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb := _verified(p_wo); i call_invoices; explained numeric; unexpl numeric; nte numeric; more numeric; notes jsonb := '[]'; x jsonb; t jsonb;
begin
  select * into i from call_invoices where work_order_id = p_wo;
  for x in select * from jsonb_array_elements(v->'visits') loop
    t := x->'trip';
    if t is null or not coalesce((t->>'known')::boolean, false) then continue; end if;
    if (t->>'slow')::boolean then
      notes := notes || to_jsonb(format('Visit %s: the drive took %s min. From near %s (about %s mi) it usually takes about %s.',
        x->>'visit_no', t->>'drive_min', coalesce(t->>'town', 'the start point'), t->>'miles', t->>'expected_min'));
    end if;
  end loop;
  -- What the bill may come to: the PO limit plus approved additions (null = no limit on this call)
  select coalesce(sum(amount) filter (where status = 'approved'), 0) into more from po_lines where work_order_id = p_wo and seq > 0;   -- seq 0 = a full-mode base line
  nte := (v->>'nte')::numeric + more;
  v := v || jsonb_build_object('approved_more', more, 'cap', nte,
    'trips', jsonb_array_length(v->'visits'),
    'auto_approve', (select c.auto_approve_bills from customers c join work_orders w on w.customer_id = c.id where w.id = p_wo));
  if i.work_order_id is null then return v || jsonb_build_object('invoice', null, 'travel_notes', notes); end if;
  explained := (v->>'billable_h')::numeric + i.other_hours;
  unexpl := greatest(0, round(i.hours_billed - explained, 2));
  if unexpl > 0 then
    for x in select * from jsonb_array_elements(v->'visits') loop
      t := x->'trip';
      if t is not null and coalesce((t->>'in_area')::boolean, false) then
        notes := notes || to_jsonb(format('Visit %s: the trip started near %s, about %s mi from the store (inside your %s-mile area). Only the %s-min drive is counted. If the extra %s h is travel from the shop, it wasn''t driven.',
          x->>'visit_no', coalesce(t->>'town', 'the store'), t->>'miles', t->>'area_mi', t->>'drive_min', trim_scale(unexpl)));
      end if;
    end loop;
  end if;
  return v || jsonb_build_object('invoice', jsonb_build_object('number', i.invoice_number, 'total', i.total, 'status', i.status,
      'agreed_hours', i.agreed_hours, 'agreed_cap', i.agreed_cap, 'auto_approved', i.auto_approved, 'side', i.entered_side),
    'billed_h', i.hours_billed, 'other_h', i.other_hours, 'other_reason', i.other_reason,
    'explained_h', explained, 'unexplained_h', unexpl,
    'under_h', greatest(0, round((v->>'billable_h')::numeric - i.hours_billed, 2)),
    'over_nte', nte is not null and i.total > nte, 'over_nte_by', case when nte is not null and i.total > nte then i.total - nte end,
    'all_verified', unexpl = 0, 'travel_notes', notes);
end $$;

create or replace function submit_invoice(p_wo uuid, p_invoice_number text, p_total numeric, p_hours_billed numeric,
  p_other_hours numeric default 0, p_other_reason text default null, p_other_photo_path text default null, p_po_number text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); w work_orders; side text; old call_invoices; chk jsonb; s sites; msg text;
begin
  select * into w from work_orders where id = p_wo for update;
  if w.id is null then raise exception 'Unknown call.'; end if;
  if is_contractor_office(w.contractor_id) then side := 'contractor';
  elsif is_customer_member(w.customer_id) and can_see_site(w.site_id) and (m.can_see_billing or m.can_approve or m.is_org_admin) then side := 'store';
  else raise exception 'Not allowed.'; end if;
  if w.mode <> 'verify' then raise exception 'Invoices for this call go through billing.'; end if;
  if w.status not in ('completed','invoiced') then raise exception 'The call must be finished before it is invoiced.'; end if;
  select * into old from call_invoices where work_order_id = w.id for update;
  if old.status = 'approved' then raise exception 'The store already approved this invoice.'; end if;
  if side = 'store' and old.entered_side = 'contractor' then raise exception 'The contractor already entered this invoice.'; end if;
  if coalesce(trim(p_invoice_number), '') = '' then raise exception 'Enter the invoice number.'; end if;
  if p_total is null or p_total < 0 then raise exception 'Enter the invoice total.'; end if;
  if p_hours_billed is null or p_hours_billed < 0 or p_hours_billed > 200 then raise exception 'Enter the hours billed.'; end if;
  if coalesce(p_other_hours, 0) < 0 then raise exception 'Other hours cannot be negative.'; end if;
  if coalesce(p_other_hours, 0) > 0 and coalesce(length(trim(p_other_reason)), 0) < 5 then
    raise exception 'Say what the other hours were for (shop work, picking up parts, …).';
  end if;

  insert into call_invoices (work_order_id, invoice_number, po_number, total, hours_billed, other_hours, other_reason, other_photo_path,
                             entered_side, entered_by, entered_at, status)
  values (w.id, trim(p_invoice_number), coalesce(nullif(trim(p_po_number), ''), _po(w)), p_total, p_hours_billed, coalesce(p_other_hours, 0),
          nullif(trim(p_other_reason), ''), nullif(trim(p_other_photo_path), ''), side, m.id, now(), 'submitted')
  on conflict (work_order_id) do update set invoice_number = excluded.invoice_number, po_number = excluded.po_number,
    total = excluded.total, hours_billed = excluded.hours_billed, other_hours = excluded.other_hours, other_reason = excluded.other_reason,
    other_photo_path = excluded.other_photo_path, entered_side = excluded.entered_side, entered_by = excluded.entered_by,
    entered_at = now(), status = 'submitted', reviewed_by = null, reviewed_at = null, review_note = null;
  chk := _invoice_check(w.id);
  update call_invoices set check_result = chk where work_order_id = w.id;

  if (chk->>'unexplained_h')::numeric > 0 then
    perform _raise_flag(w.id, 'invoice_unexplained', format('Invoice %s bills %s h; %s h verified/expected%s — %s h not explained.',
      trim(p_invoice_number), chk->>'billed_h', chk->>'billable_h',
      case when coalesce(p_other_hours, 0) > 0 then format(' + %s h %s', p_other_hours, trim(p_other_reason)) else '' end,
      chk->>'unexplained_h'), false, true);
  else
    update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Invoice hours match'
     where work_order_id = w.id and flag = 'invoice_unexplained' and resolved_at is null;
  end if;
  if (chk->>'over_nte')::boolean then
    perform _raise_flag(w.id, 'invoice_over_nte', format('Invoice total $%s is over the $%s this call allows (PO limit plus approved additions) by $%s.',
      p_total, chk->>'cap', chk->>'over_nte_by'), false, true);
  else
    update guardrail_flags set resolved_at = now(), resolved_by = m.id, resolution_note = 'Within the not-to-exceed'
     where work_order_id = w.id and flag = 'invoice_over_nte' and resolved_at is null;
  end if;
  update guardrail_flags set resolved_at = now(), resolution_note = 'Invoice entered'
   where work_order_id = w.id and flag = 'billing_late' and resolved_at is null;

  perform _allow_internal(true);
  update work_orders set status = 'invoiced', invoiced_at = coalesce(invoiced_at, now()), qbo_invoice_id = trim(p_invoice_number)
   where id = w.id returning * into w;
  perform _end_internal();

  msg := format('Invoice %s for call #%s (%s): $%s, %s h billed — %s.', trim(p_invoice_number), w.number, _po(w), p_total, p_hours_billed,
    case when (chk->>'unexplained_h')::numeric > 0 then format('%s h verified/expected, %s h NOT explained', chk->>'billable_h', chk->>'unexplained_h')
         else 'hours match what was verified' end)
    || case when (chk->>'over_nte')::boolean then format(' Over your $%s limit by $%s.', chk->>'cap', chk->>'over_nte_by') else '' end;
  if side = 'contractor' then
    perform _notify_customer(w.id, 'billing_due', msg);
  else
    perform _notify_office(w.id, 'billing_due', format('%s (store) entered your invoice for call #%s from their copy: %s Please check it.',
      m.full_name, w.number, msg));
  end if;
  return chk;
end $$;


-- Contractor (or store, from a paper invoice) sends the bill.
--   p_agree_hours: the contractor agrees to the verified hours. Otherwise p_hours (+ p_reason when more than verified).
--   p_over_ok: send it anyway when the total is over what the call allows; it's flagged to the store.
create or replace function send_bill(p_wo uuid, p_invoice_number text, p_total numeric, p_agree_hours boolean,
  p_hours numeric default null, p_reason text default null, p_over_ok boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare w work_orders; side text; pre jsonb; chk jsonb; cap numeric; billable numeric; hrs numeric; other numeric := 0; auto boolean := false;
begin
  select * into w from work_orders where id = p_wo;
  if w.id is null then raise exception 'Unknown call.'; end if;
  side := case when is_contractor_office(w.contractor_id) then 'contractor' else 'store' end;
  pre := _invoice_check(p_wo);
  billable := (pre->>'billable_h')::numeric;
  cap := (pre->>'cap')::numeric;
  if side = 'contractor' and coalesce(p_agree_hours, false) then
    hrs := billable;
  else
    if p_hours is null or p_hours < 0 then raise exception 'Enter the hours on your bill.'; end if;
    hrs := p_hours;
    if side = 'contractor' and hrs > billable then other := hrs - billable; end if;
  end if;
  if cap is not null and p_total > cap and not coalesce(p_over_ok, false) then
    raise exception 'Your total is over the $% this call allows (PO limit plus approved additions). Request approval for more first, or send it marked over the PO.', cap;
  end if;
  chk := submit_invoice(p_wo, p_invoice_number, p_total, hrs, other, case when other > 0 then p_reason end);
  auto := side = 'contractor' and coalesce(p_agree_hours, false) and (cap is null or p_total <= cap)
          and (chk->>'all_verified')::boolean and not coalesce((chk->>'over_nte')::boolean, false)
          and coalesce((select auto_approve_bills from customers where id = w.customer_id), false);
  update call_invoices set agreed_hours = case when side = 'contractor' then coalesce(p_agree_hours, false) end,
         agreed_cap = case when side = 'contractor' then (cap is null or p_total <= cap) end,
         auto_approved = auto,
         status = case when auto then 'approved' else status end,
         reviewed_at = case when auto then now() else reviewed_at end,
         review_note = case when auto then 'Approved automatically: the contractor agreed to the verified hours and the bill is within the PO.' else review_note end
   where work_order_id = p_wo;
  if auto then
    perform _notify_customer(p_wo, 'billing_due', format('Invoice %s for call #%s was approved automatically: hours agreed and within the PO.', trim(p_invoice_number), w.number));
    perform _notify_office(p_wo, 'billing_due', format('Invoice %s for call #%s was approved automatically.', trim(p_invoice_number), w.number));
  end if;
  return _invoice_check(p_wo);
end $$;
revoke execute on function send_bill(uuid, text, numeric, boolean, numeric, text, boolean) from public, anon;
grant execute on function send_bill(uuid, text, numeric, boolean, numeric, text, boolean) to authenticated;
