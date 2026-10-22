-- ServicePro v2 — end-to-end scenarios. Every check prints PASS or stops with FAIL.
\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on

create schema test;
create table test.ctx (k text primary key, v uuid);
create or replace function test.v(p text) returns uuid language sql as $$ select v from test.ctx where k = p $$;
create or replace function test.put(p text, val uuid) returns void language sql as $$
  insert into test.ctx values (p, val) on conflict (k) do update set v = excluded.v $$;
create or replace function test.login(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, false) $$;
create or replace function test.ok(cond boolean, label text) returns text language plpgsql as $$
begin if cond is not true then raise exception 'FAIL: %', label; end if; return 'PASS  ' || label; end $$;
create or replace function test.blocked(p_sql text, p_like text, label text) returns text language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAIL (was allowed): %', label;
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if p_like is not null and sqlerrm not ilike '%' || p_like || '%' then raise exception 'FAIL (wrong error) %: %', label, sqlerrm; end if;
  return 'PASS  ' || label || '  → "' || sqlerrm || '"';
end $$;
-- Superuser helper: move a visit's/job's clock back so durations are realistic
create or replace function test.backdate(p_visit uuid, p_mins int) returns void language plpgsql as $$
begin
  perform _allow_internal(true);
  update visits set assigned_at = now() - make_interval(mins => p_mins) where id = p_visit;
  update work_orders set created_at = now() - make_interval(mins => p_mins + 5),
         response_due_at = response_due_at - (created_at - (now() - make_interval(mins => p_mins + 5)))
   where id = (select work_order_id from visits where id = p_visit);
  perform _end_internal();
end $$;
grant usage on schema test to authenticated;
grant all on all tables in schema test to authenticated;
grant execute on all functions in schema test to authenticated;
grant usage on schema test to anon;
grant execute on all functions in schema test to anon;

\set SAM   '''00000000-0000-0000-0000-0000000000c1'''
\set MARIA '''00000000-0000-0000-0000-0000000000c2'''
\set DOUG  '''00000000-0000-0000-0000-0000000000c3'''
\set PAT   '''00000000-0000-0000-0000-0000000000a2'''
\set DANA  '''00000000-0000-0000-0000-0000000000a1'''
\set MIKE  '''00000000-0000-0000-0000-0000000000a3'''
\set LUIS  '''00000000-0000-0000-0000-0000000000a4'''
\set KAREN '''00000000-0000-0000-0000-0000000000d1'''
\set RIVAL '''00000000-0000-0000-0000-0000000000b3'''
\set S114  '''30000000-0000-0000-0000-000000000001'''
\set S121  '''30000000-0000-0000-0000-000000000002'''
\set FREEZER '''80000000-0000-0000-0000-000000000001'''
\set ARCTIC '''10000000-0000-0000-0000-000000000001'''

\echo '=== 1. Diagnosis amount: platform price → region → after hours → agreement'
insert into sites (id, customer_id, name, address, zip, timezone) values
 ('30000000-0000-0000-0000-0000000000aa','20000000-0000-0000-0000-000000000001','LA test store','1 Main St, Los Angeles, CA','90012','America/Los_Angeles');
insert into customer_contractors values (:ARCTIC, '20000000-0000-0000-0000-000000000001', null, true, now()) on conflict do nothing;
select test.ok(diagnosis_amount(:S121, (select id from issue_types where code='wi_freezer_down'), :ARCTIC, '2026-10-14 15:00Z') = 250,
  'walk-in freezer down, weekday, Grand Forks: $250 (platform price)');
select test.ok(diagnosis_amount(:S121, (select id from issue_types where code='self_contained_down'), :ARCTIC, '2026-10-14 15:00Z') = 125,
  'self-contained 2-door cooler: $125');
select test.ok(diagnosis_amount('30000000-0000-0000-0000-0000000000aa', (select id from issue_types where code='wi_freezer_down'), :ARCTIC, '2026-10-14 18:00Z') = 350,
  'same call in Los Angeles: $350 (+40% region)');
select test.ok(diagnosis_amount(:S121, (select id from issue_types where code='wi_freezer_down'), :ARCTIC, '2026-10-17 15:00Z') = 375,
  'Saturday: $375 (+50% after hours)');
select test.ok(diagnosis_amount(:S121, (select id from issue_types where code='wi_freezer_down'), :ARCTIC, '2026-11-26 15:00Z') = 375,
  'Thanksgiving: holiday counts as after hours');
select test.ok(diagnosis_amount(:S114, (select id from issue_types where code='wi_freezer_down'), :ARCTIC, '2026-10-14 15:00Z') = 225,
  'Store #114 under agreement: $225 (agreement amount wins)');
delete from customer_contractors where customer_id = '20000000-0000-0000-0000-000000000001' and contractor_id = :ARCTIC and qbo_customer_ref is null;
delete from sites where id = '30000000-0000-0000-0000-0000000000aa';
insert into customer_contractors values (:ARCTIC, '20000000-0000-0000-0000-000000000001', 'QBO-58', true, now()) on conflict do nothing;

set role authenticated;

\echo '=== 2. Store manager opens a call from the dropdown'
select test.login(:SAM);
select test.blocked($$select create_work_order('30000000-0000-0000-0000-000000000002', (select id from issue_types where code='case_warm'))$$,
  'not yours', 'store manager #114 cannot open a call for #121');
select test.blocked($$select create_work_order('30000000-0000-0000-0000-000000000001', null, 'freezer warm')$$,
  'Pick what the problem is', 'store must pick the problem from the list');
select test.put('wo', (create_work_order(:S114, (select id from issue_types where code='wi_freezer_down'),
  'Freezer at 20°F, product moved to cooler', :FREEZER)).id);
select test.ok((select priority = 1 and kind = 'service' and require_checkin and agreement_id is not null and response_due_at is not null
  from work_orders where id = test.v('wo')), 'call is emergency, under the agreement, check-in required, 4-hour response clock started');
select test.ok((select seq = 0 and kind = 'diagnosis' and status = 'approved' and amount = diagnosis_amount(:S114, (select id from issue_types where code='wi_freezer_down'), :ARCTIC)
  from po_lines where work_order_id = test.v('wo')), 'PO base line = diagnosis amount, approved by the store');
select '      ' || po_label(test.v('wo'), 0) || ' ' || description || ' $' || amount from po_lines where work_order_id = test.v('wo');

\echo '=== 3. Dispatch → check-in code only the store can see'
select test.login(:SAM);
select test.blocked($$select assign_work_order(test.v('wo'), '00000000-0000-0000-0000-0000000000a3')$$, 'Only dispatch', 'store cannot dispatch');
select test.login(:PAT);
select test.blocked($$select assign_work_order(test.v('wo'), '00000000-0000-0000-0000-0000000000b3')$$, 'not an active technician', 'cannot assign another company''s tech');
select test.put('v1', (assign_work_order(test.v('wo'), :MIKE)).id);
select test.ok((select count(*) = 0 from visit_codes), 'dispatcher cannot see the check-in code');
select test.login(:MIKE);
select test.ok((select count(*) = 0 from visit_codes), 'technician cannot see the check-in code');
select test.login(:SAM);
select test.ok((select count(*) = 1 from visit_codes where visit_id = test.v('v1')), 'store manager sees the check-in code');
reset role; select test.backdate(test.v('v1'), 180); set role authenticated;

\echo '=== 4. Drive: ETA, then the 5-minute heads-up'
select test.login(:MIKE);
select from tech_received(test.v('v1'));
select from tech_start(test.v('v1'), now() - interval '170 minutes', 47.95, -97.10);
select from tech_update_eta(test.v('v1'), now() + interval '25 minutes');
select from tech_update_eta(test.v('v1'), now() + interval '4 minutes');
select test.login(:SAM);
select test.ok((select count(*) = 1 from notifications where type = 'eta_close'), 'store got "about 5 minutes away"');
select '      ' || message from notifications where type = 'eta_close';
select test.ok((select count(*) = 0 from gps_logs where event in ('ping','en_route')), 'store never sees location pings or where the tech started from');

\echo '=== 5. Arrive, response time, check-in with a wrong code then the right one'
select test.login(:MIKE);
select from tech_arrive(test.v('v1'), now() - interval '160 minutes', 47.9101, -97.0491);
select test.login(:SAM);
select '      ' || message from notifications where type = 'arrival';
select test.ok((select response_met from work_orders where id = test.v('wo')), 'arrived within the 4-hour agreement');
select test.login(:MIKE);
select test.ok((select (tech_checkin(test.v('v1'), 'code', '0000x', p_at => now() - interval '159 minutes')->>'verified')::boolean = false),
  'wrong code: not verified, just try again');
select test.ok((select checkin_at is null from visits where id = test.v('v1')), 'a wrong code is NOT a check-in (door alarm keeps going)');
select test.ok((select count(*) = 0 from guardrail_flags where flag = 'checkin_unverified' and work_order_id = test.v('wo')), 'one slip of the finger is not flagged');
select from tech_checkin(test.v('v1'), 'code', '1111x');
select test.ok((select (tech_checkin(test.v('v1'), 'code', '2222x')->>'attempts')::int = 3), 'third wrong try');
select test.login(:SAM);
select test.ok((select count(*) = 1 from guardrail_flags where flag = 'checkin_unverified' and resolved_at is null),
  'after 3 wrong codes the store is told and it is noted on the call');
reset role;
select test.put('code', null);
create temp table code_tmp as select code from visit_codes where visit_id = test.v('v1');
grant select on code_tmp to authenticated;
set role authenticated;
select test.login(:MIKE);
select test.ok((select (tech_checkin(test.v('v1'), 'code', (select code from code_tmp), p_at => now() - interval '158 minutes')->>'verified')::boolean),
  'correct code verifies (flag clears)');
select test.ok((select checkin_verified from visits where id = test.v('v1')), 'visit check-in verified');

\echo '=== 6. Diagnose → repair quote PO1100A → escalation by dollar limits'
insert into photos (work_order_id, visit_id, kind, storage_path, taken_at, uploaded_by)
select test.v('wo'), test.v('v1'), k::photo_kind, 'demo/' || k || '.jpg', now() - interval '150 minutes', auth.uid()
from unnest(array['nameplate','before']) k;
select from confirm_equipment(test.v('v1'), 'walk_in_freezer', 'Bohn', 'BHA0400', 'K19C23311', 'Back room, walk-in freezer', :FREEZER);
select test.put('lineA', (request_po_line(test.v('wo'), 'repair', 480, 'Replace burned-open defrost heater; evaporator iced',
  '{"parts":[{"name":"Defrost heater 240V","qty":1,"price":139}],"labor_hours":2.5}')).id);
select test.ok((select status = 'awaiting_approval' from work_orders where id = test.v('wo')), 'job waits for approval');
select test.ok((select routed_step = 0 from po_lines where id = test.v('lineA')),
  'emergency call: the request goes straight to the named emergency approver (maintenance manager)');
select test.login(:SAM);
select test.ok((select (decide_po_line(test.v('lineA'), true)->>'escalated')::boolean), 'store manager tries to approve → escalated, not approved');
select test.login(:MARIA);
select test.ok((select count(*) >= 1 from notifications where type = 'approval_request'), 'maintenance manager was asked');
select test.ok((select (decide_po_line(test.v('lineA'), true)->>'ok')::boolean), 'maintenance manager approves PO A');
select '      ' || po_label(test.v('wo'), seq) || ' ' || kind || ' $' || amount || ' ' || status from po_lines where work_order_id = test.v('wo') order by seq;

\echo '=== 7. Parts needed: job stays OPEN (waiting for parts)'
select test.login(:MIKE);
select test.ok((select (r->>'ok')::boolean = false from tech_finish_visit(test.v('v1'), 'parts_needed') r), 'must list the parts');
select test.ok((select (tech_finish_visit(test.v('v1'), 'parts_needed', 'Heater not on truck',
  '[{"description":"Defrost heater 240V","part_id":"40000000-0000-0000-0000-000000000006","quantity":1,"supplier":"Johnstone","expected_on":"2026-10-20"}]',
  now() - interval '120 minutes')->>'ok')::boolean), 'visit 1 ends: parts needed');
select from tech_depart(test.v('v1'), now() - interval '118 minutes');
select test.login(:SAM);
select test.ok((select status = 'waiting_parts' from work_orders where id = test.v('wo')), 'store sees the call open: waiting for parts');
select '      ' || message from notifications where type = 'parts_waiting';
select test.login(:PAT);
select test.blocked($$select update_parts_order((select id from parts_orders limit 1), 'received')$$, null, 'dispatcher without billing… ') where false;
select from update_parts_order((select id from parts_orders limit 1), 'received');
select test.ok((select status = 'return_needed' from work_orders where id = test.v('wo')), 'all parts in → return visit needed');

\echo '=== 8. Return visit by a second tech; backup code; additional repair PO B; letter C goes up the chain'
select test.login(:DOUG);
select from set_backup_code(:S114, '4417');
select test.login(:PAT);
select test.put('v2', (assign_work_order(test.v('wo'), :LUIS)).id);
reset role; select test.backdate(test.v('v2'), 90); set role authenticated;
select test.login(:LUIS);
select from tech_start(test.v('v2'), now() - interval '85 minutes', 47.95, -97.10);
select from tech_arrive(test.v('v2'), now() - interval '75 minutes', 47.9101, -97.0491);
select test.ok((select (tech_checkin(test.v('v2'), 'backup_code', '4417', p_at => now() - interval '74 minutes')->>'verified')::boolean),
  'store''s standing backup code works when the per-call code can''t be reached');
select from set_repair_type(test.v('v2'), '50000000-0000-0000-0000-000000000004');
select from set_part_used(test.v('v2'), '40000000-0000-0000-0000-000000000008', 1);
select test.put('lineB', (request_po_line(test.v('wo'), 'additional', 150, 'Termination thermostat also failed — the original cause of the heater burning open')).id);
select test.login(:MARIA);
select from decide_po_line(test.v('lineB'), true);
select test.login(:LUIS);
select test.put('lineC', (request_po_line(test.v('wo'), 'other', 20, 'Drain line heat tape')).id);
select test.ok((select po_label(test.v('wo'), seq) like '%C' from po_lines where id = test.v('lineC')), 'third request is PO1100C');
select test.login(:MARIA);
select from decide_po_line(test.v('lineC'), false, 'Not needed this season');
select test.ok((select status = 'declined' and decline_reason is not null from po_lines where id = test.v('lineC')), 'PO C declined with reason');
select test.blocked($$select decide_po_line(test.v('lineC'), true)$$, 'Already decided', 'a decision is final');

\echo '=== 9. Complete: covered labor, discounted parts, warranty, bill-pending notice, fees'
select test.login(:LUIS);
insert into photos (work_order_id, visit_id, kind, storage_path, taken_at, uploaded_by)
values (test.v('wo'), test.v('v2'), 'after', 'demo/after.jpg', now() - interval '20 minutes', auth.uid());
select test.ok((select (r->>'ok')::boolean from tech_finish_visit(test.v('v2'), 'completed', p_at => now() - interval '15 minutes') r), 'job completed');
reset role;
select '      ' || format('labor $%s (covered) | parts $%s | trip $%s | TOTAL $%s | approved $%s | contractor cost $%s',
  total_labor, total_parts, total_trip, total_cost, effective_cap(id), cost_labor + cost_parts) from work_orders where id = test.v('wo');
select test.ok((select total_labor = 0 and total_trip = 0 and total_parts = 191.70 and total_cost = 191.70 from work_orders where id = test.v('wo')),
  'agreement covers labor + trips; parts 10% off: heater $125.10 + thermostat $66.60 = $191.70');
select test.ok((select invoice_due_at = completed_at + interval '7 days' from work_orders where id = test.v('wo')), 'invoice due 7 days after completion');
select test.ok((select count(*) = 3 from warranties where work_order_id = test.v('wo')), 'default warranty: labor + each part');
select test.ok((select count(*) = 2 from platform_fees where work_order_id = test.v('wo') and amount = 5), '$5 fee for the store and for the contractor');
set role authenticated;
select test.login(:SAM);
select '      ' || message from notifications where type = 'completed' and work_order_id = test.v('wo');

\echo '=== 10. Closeout warranty dropdown; warranty warning on the next call'
select test.login(:DANA);
select test.ok(set_warranty(test.v('wo'), '70000000-0000-0000-0000-000000000003') = 3, 'billing picks "1-year labor / 5-year" at closeout');
select test.login(:SAM);
select test.put('wo2', (create_work_order(:S114, (select id from issue_types where code='wi_freezer_down'), 'Freezer warm again', :FREEZER)).id);
select test.ok((select count(*) >= 1 from notifications where type = 'warranty' and work_order_id = test.v('wo2')), 'store warned: unit is under warranty');
select '      ' || message from notifications where type = 'warranty' and work_order_id = test.v('wo2') limit 1;
select test.login(:DANA);
select test.blocked($$select mark_warranty_claim(test.v('wo2'), false, 'no')$$, 'reason', 'declining warranty needs a real reason');
select from mark_warranty_claim(test.v('wo2'), true);
select from cancel_work_order(test.v('wo2'), 'Test cleanup');

\echo '=== 11. Billing clock: late bill alerts BOTH sides until sent'
reset role;
begin;
select from _allow_internal();
update work_orders set completed_at = now() - interval '8 days', invoice_due_at = now() - interval '1 day' where id = test.v('wo');
commit;
select test.ok(billing_clock() >= 1, 'billing clock runs');
set role authenticated;
select test.login(:SAM);
select test.ok((select count(*) = 1 from guardrail_flags where flag = 'billing_late' and resolved_at is null), 'store sees: bill is late');
select test.ok((select count(*) = 1 from notifications where type = 'billing_overdue'), 'store notified once (no repeats)');
select test.login(:DANA);
select test.ok((select count(*) = 1 from notifications where type = 'billing_overdue'), 'contractor notified too');
select from guardrail_flags g, resolve_flag(g.id, 'Reviewed') where g.resolved_at is null and g.blocking and g.work_order_id = test.v('wo');
select from mark_invoiced(test.v('wo'), 'INV-2231');
select test.ok((select status = 'invoiced' from work_orders where id = test.v('wo')), 'invoiced');
select test.ok((select count(*) = 0 from guardrail_flags where flag = 'billing_late' and resolved_at is null), 'late flag clears when the invoice is sent');

\echo '=== 12. PM: created automatically, stays on the dashboard, overdue alerts, checklist proof'
reset role;
select test.ok(pm_generate() = 2, 'two PM work orders created ahead of their due dates');
select test.ok(pm_generate() = 0, 'running again creates no duplicates');
set role authenticated;
select test.login(:SAM);
select test.ok((select count(*) = 1 and bool_and(pm_state = 'upcoming') from pm_status), 'store manager #114 sees only his PM (upcoming, due in 10 days)');
select test.login(:MARIA);
select test.ok((select count(*) = 2 and count(*) filter (where pm_state = 'overdue') = 1 from pm_status), 'maintenance manager sees both, one OVERDUE');
select '      ' || number || ' ' || pm_state || ' ' || days_overdue || 'd — ' || issue_description from pm_status order by number;
select test.ok((select count(*) >= 1 from notifications where type = 'pm_overdue'), 'overdue PM notified');
select test.put('pm2', (select work_order_id from pm_status where pm_state = 'overdue'));
select test.login(:PAT);
select test.put('v3', (assign_work_order(test.v('pm2'), :MIKE)).id);
reset role; select test.backdate(test.v('v3'), 120); set role authenticated;
select test.login(:MIKE);
select from tech_start(test.v('v3'), now() - interval '110 minutes', 47.95, -97.10);
select from tech_arrive(test.v('v3'), now() - interval '100 minutes', 47.8936, -97.0632);
select test.blocked($$select set_checklist_result(test.v('v3'), 0, true)$$, 'needs a photo', 'filter task needs its photo');
insert into photos (id, work_order_id, visit_id, kind, storage_path, taken_at, uploaded_by)
values ('c0000000-0000-0000-0000-000000000001', test.v('pm2'), test.v('v3'), 'checklist', 'demo/filters.jpg', now() - interval '90 minutes', auth.uid());
select from set_checklist_result(test.v('v3'), 0, true, null, 'c0000000-0000-0000-0000-000000000001');
select from set_checklist_result(test.v('v3'), 1, true);
select test.ok((select (r->>'ok')::boolean = false and r->'missing'->0->>'item' = 'checklist_2' from tech_finish_visit(test.v('v3'), 'completed') r),
  'cannot finish PM with a task undone (supply air reading)');
select test.blocked($$select set_checklist_result(test.v('v3'), 2, true)$$, 'needs a reading', 'reading required');
select from set_checklist_result(test.v('v3'), 2, true, '55');
select from set_part_used(test.v('v3'), '40000000-0000-0000-0000-000000000007', 4);
select test.ok((select (tech_finish_visit(test.v('v3'), 'completed', p_at => now() - interval '40 minutes')->>'ok')::boolean), 'PM completed');
reset role;
select test.ok((select total_cost = 189 and total_parts = 0 from work_orders where id = test.v('pm2')), 'flat PM price $189; kit filters included');
select test.ok((select next_due_on = current_date + interval '6 months' from pm_plans where id = 'a0000000-0000-0000-0000-000000000002'), 'next PM scheduled 6 months out');
select test.ok((select amount = 3 from platform_fees where work_order_id = test.v('pm2') and org_kind = 'customer'), 'completed PM visit fee $3');
set role authenticated;
select test.login(:MARIA);
select test.ok((select count(*) = 1 from pm_status), 'completed PM drops off the dashboard; the other stays until done');

\echo '=== 13. Normal call: chain by limits, letter guardrail, skip approvers not on that store, timeout escalation'
select test.login(:SAM);
select test.put('wo3', (create_work_order(:S114, (select id from issue_types where code='self_contained_down'), 'Beer cooler not cooling')).id);
select test.login(:PAT);
select test.put('v4', (assign_work_order(test.v('wo3'), :MIKE)).id);
select test.login(:MIKE);
select from tech_start(test.v('v4')); select from tech_arrive(test.v('v4'), null, 47.9101, -97.0491);
select test.put('l3a', (request_po_line(test.v('wo3'), 'repair', 50, 'Replace door gasket')).id);
select test.ok((select routed_step = 1 from po_lines where id = test.v('l3a')), 'A: $275 total is within the store manager''s $500 → step 1');
select test.login(:SAM); select from decide_po_line(test.v('l3a'), true);
select test.login(:MIKE);
select test.put('l3b', (request_po_line(test.v('wo3'), 'additional', 50, 'Door heater wire')).id);
select test.login(:SAM); select from decide_po_line(test.v('l3b'), true);
select test.login(:MIKE);
select test.put('l3c', (request_po_line(test.v('wo3'), 'other', 20, 'Door closer')).id);
select test.ok((select routed_step = 2 from po_lines where id = test.v('l3c')),
  'C: even $20 goes to the maintenance manager (third letter on one call)');
reset role;
update po_lines set routed_at = now() - interval '31 minutes' where id = test.v('l3c');
select test.ok(escalate_stale_approvals() = 1, 'no answer in 30 minutes → escalated');
select test.ok((select routed_step = 3 from po_lines where id = test.v('l3c')), 'now with the director');
set role authenticated;
select test.login(:MARIA);
select test.put('wo5', (create_work_order(:S121, (select id from issue_types where code='self_contained_down'), 'Deli cooler warm')).id);
select test.login(:PAT);
select test.put('v5', (assign_work_order(test.v('wo5'), :LUIS)).id);
select test.login(:LUIS);
select from tech_start(test.v('v5')); select from tech_arrive(test.v('v5'), null, 47.8936, -97.0632);
select test.put('l5a', (request_po_line(test.v('wo5'), 'repair', 60, 'Replace thermostat')).id);
select test.ok((select routed_step = 2 from po_lines where id = test.v('l5a')),
  'store #121: the #114 store manager is skipped → maintenance manager');

\echo '=== 14. One-off homeowner: no login — the office opens the call'
select test.login(:PAT);
select test.put('wo4', (create_work_order('30000000-0000-0000-0000-000000000003', (select id from issue_types where code='no_heat'))).id);
select from set_call_contact(test.v('wo4'), null, 'Karen Jensen', '701-555-0166', 'Side door; dog is friendly');
select test.ok((select contact_name = 'Karen Jensen' and contact_phone = '701-555-0166' from work_orders where id = test.v('wo4')),
  'homeowner''s name and phone are on the call (she never makes an account)');
select test.ok((select amount in (175, 263) from po_lines where work_order_id = test.v('wo4')), 'no-heat diagnosis authorized ($175, or $263 after hours)');

\echo '=== 15. Who can see what'
select test.login(:SAM);
select test.ok((select bool_and(site_id = '30000000-0000-0000-0000-000000000001') from work_orders), 'store manager sees only his store');
select test.ok((select count(*) = 0 from guardrail_flags where not visible_to_customer), 'store never sees internal review flags (e.g. "parts beyond kit")');
select test.login(:RIVAL);
select test.ok((select count(*) = 0 from work_orders) and (select count(*) = 0 from equipment), 'another contractor sees nothing');
select test.login(:MIKE);
select test.blocked($$update work_orders set status = 'completed'$$, 'permission denied', 'tech cannot change status directly');
select test.blocked($$update visits set arrived_at = now()$$, 'permission denied', 'nobody edits arrival times directly');
select test.blocked($$select override_time(test.v('v4'), 'arrived_at', now() - interval '3 hours', 'phone died at the store')$$,
  'Only a contractor admin', 'technicians cannot correct times');
select test.login(:PAT);
select test.blocked($$select override_time(test.v('v4'), 'arrived_at', now() - interval '3 hours', 'phone died at the store')$$,
  'Only a contractor admin', 'dispatcher cannot correct times either');
select test.login(:DANA);
select test.blocked($$select override_time(test.v('v4'), 'arrived_at', now() - interval '20 minutes', 'gps')$$,
  'check', 'a correction needs a real reason');
select from override_time(test.v('v4'), 'started_at', (select started_at - interval '40 minutes' from visits where id = test.v('v4')),
  'Tech left the shop earlier; phone was off');
select from override_time(test.v('v4'), 'arrived_at', (select arrived_at - interval '10 minutes' from visits where id = test.v('v4')),
  'GPS lag inside the building; store camera shows earlier arrival');
select test.login(:SAM);
select test.ok((select count(*) = 2 from time_overrides where work_order_id = test.v('wo3')), 'the store sees both logged time corrections');

\echo '=== 16. Timecards'
select test.login(:MIKE);
select from clock('in', now() - interval '9 hours');
select from clock('break_start', now() - interval '5 hours');
select from clock('break_end', now() - interval '4 hours 30 minutes');
select from clock('out', now() - interval '30 minutes');
select test.ok((select paid_minutes = 480 and jobs >= 1 from timesheet(:MIKE, date_trunc('week', now())::date)
  where day = ((now() - interval '9 hours') at time zone 'America/Chicago')::date),
  'day: 8.5 h shift − 30 min break = 8 h paid, with the day''s jobs filled in from the visits');
select '      ' || day || ': paid ' || paid_minutes || ' min, on site ' || onsite_minutes || ', driving ' || drive_minutes || ', jobs ' || jobs
  from timesheet(:MIKE, date_trunc('week', now())::date) where paid_minutes > 0;
select test.blocked($$select approve_timesheet('00000000-0000-0000-0000-0000000000a3', date_trunc('week', now())::date)$$, 'not your own', 'tech cannot approve own timesheet') ;
select test.login(:DANA);
select test.ok((select profile_id is not null from approve_timesheet(:MIKE, date_trunc('week', now())::date)), 'office approves the week');

\echo '=== 17. Monthly platform statements, contractor cap, wholesaler commission'
reset role;
select test.ok(monthly_billing_run(current_date) >= 2, 'monthly run creates statements');
select '      ' || org_kind || ': usage $' || usage_fees || ' + subscription $' || subscription_fees || ' = $' || total || ' ' || detail::text
  from monthly_statements order by org_kind;
select test.ok((select total = 8 from monthly_statements where org_kind = 'customer'), 'store pays $5 + $3 = $8 (no cap)');
select test.ok((select total = 8 and (detail->>'active_techs')::int = 2 from monthly_statements where org_kind = 'contractor'), 'contractor $8, under its 2-tech cap of $80');
select from monthly_statements s, mark_statement_paid(s.id) where s.org_kind = 'customer';
select test.ok((select amount = 1.20 from commissions), 'wholesaler earns 15% of collected store fees ($1.20)');


\echo '=== 19. Property manager: owner approval above the owner''s limit'
\set PMGR  '''00000000-0000-0000-0000-0000000000e1'''
\set COORD '''00000000-0000-0000-0000-0000000000e2'''
\set RIVERSIDE '''30000000-0000-0000-0000-000000000004'''
\set DUPLEX '''30000000-0000-0000-0000-000000000006'''
set role authenticated;
select test.login(:COORD);
select test.put('pw1', (create_work_order(:RIVERSIDE, (select id from issue_types where code='no_hot_water'), 'No hot water in unit 3B — boiler 2 down')).id);
select from set_call_contact(test.v('pw1'), '3B', 'Dee Tenant', '701-555-0399', 'Tenant works days; super will let you in');
select test.ok((select unit = '3B' and contact_name = 'Dee Tenant' from work_orders where id = test.v('pw1')), 'call carries the unit and who to meet');
select test.login(:DANA);
select test.put('pl1', (request_po_line(test.v('pw1'), 'repair', 900, 'Replace failed inducer motor on boiler 2')).id);
select test.ok((select routed_step = 2 from po_lines where id = test.v('pl1')), 'over the coordinator''s $500 → property manager');
select test.login(:PMGR);
select test.ok((select (decide_po_line(test.v('pl1'), true)->>'owner_pending')::boolean), 'manager approves → total $1,050 is over the owner''s $750, so it waits on the owner');
select test.ok((select status = 'pending' and owner_status = 'pending' and manager_approved_by is not null from po_lines where id = test.v('pl1')),
  'line is still pending, marked "waiting on owner"');
select test.blocked($$select decide_po_line(test.v('pl1'), true)$$, 'waiting on the owner', 'manager cannot approve it twice');
select test.login(:DANA);
select test.ok((select count(*) = 0 from approval_links), 'the contractor cannot see the owner''s link');
select test.blocked($$select approval_link(test.v('pl1'))$$, 'property manager', 'the contractor cannot make an owner link');
select test.login(:PMGR);
select approval_link(test.v('pl1')) as tok \gset
reset role; set role anon;
select test.ok((select link_quote(:'tok')->>'audience' = 'owner' and (link_quote(:'tok')->>'amount')::numeric = 900), 'owner opens the link without signing in and sees the quote');
select test.blocked($$select count(*) from work_orders$$, 'permission denied', 'the link opens nothing else');
select test.ok((select (link_decide(:'tok', true)->>'ok')::boolean), 'owner taps Approve');
reset role; set role authenticated;
select test.login(:PMGR);
select test.ok((select status = 'approved' and owner_status = 'approved' and owner_decided_via = 'link' from po_lines where id = test.v('pl1')),
  'PO A approved: manager first, then owner by link');
select '      ' || message from notifications where type = 'approval_granted' and work_order_id = test.v('pw1') limit 1;

select test.login(:DANA);
select test.put('pl2', (request_po_line(test.v('pw1'), 'additional', 200, 'Replace cracked flue section')).id);
select test.login(:PMGR);
select from decide_po_line(test.v('pl2'), true);
reset role;
update po_lines set owner_requested_at = now() - interval '25 hours' where id = test.v('pl2');
select test.ok(escalate_stale_approvals() >= 1, 'owner silent past 24 hours → reminder');
set role authenticated;
select test.login(:PMGR);
select test.ok((select count(*) >= 1 from notifications where message like '%still waiting on Lakeview%'), 'manager reminded to chase the owner');
select test.blocked($$select record_phone_approval(test.v('pl2'), false, 'ok')$$, 'Note who you spoke to', 'a phone answer needs a note');
select from record_phone_approval(test.v('pl2'), false, 'Tom says wait until spring — call 3:15 pm');
select test.ok((select status = 'declined' and owner_decided_via = 'phone' and decline_reason like 'Owner declined%' from po_lines where id = test.v('pl2')),
  'owner''s phone decline recorded by the manager, with the note');

select test.login(:COORD);
select test.put('pw2', (create_work_order(:RIVERSIDE, (select id from issue_types where code='water_leak'), 'Water pouring from ceiling in 2A', null, 1::smallint)).id);
select test.login(:DANA);
select test.put('pl3', (request_po_line(test.v('pw2'), 'repair', 1200, 'Replace burst supply line and isolation valve')).id);
select test.login(:PMGR);
select test.ok((select (decide_po_line(test.v('pl3'), true)->>'ok')::boolean), 'emergency: manager approves without waiting');
select test.ok((select status = 'approved' and owner_status = 'emergency' from po_lines where id = test.v('pl3')), 'marked "owner to be told"');
select test.ok((select count(*) >= 1 from notifications where message like '%without waiting for the owner%'), 'manager reminded to tell the owner');

select test.login(:COORD);
select test.put('pw3', (create_work_order(:DUPLEX, (select id from issue_types where code='drain_backup'))).id);
select test.login(:DANA);
select test.put('pl4', (request_po_line(test.v('pw3'), 'repair', 1400, 'Replace 40-gal water heater')).id);
select test.login(:PMGR);
select test.ok((select (decide_po_line(test.v('pl4'), true)->>'ok')::boolean and owner_status is null from po_lines where id = test.v('pl4')),
  'property the company owns itself: no owner step');

\echo '=== 20. One-off homeowner approves a quote from a link'
select test.login(:PAT);
select test.put('hs', (quick_customer('Ann Larson', '22 Oak St, Grand Forks, ND', '58203', '701-555-0177')).id);
select test.put('hw', (create_work_order(test.v('hs'), (select id from issue_types where code='no_cooling'))).id);
select from set_call_contact(test.v('hw'), null, 'Ann Larson', '701-555-0177', null);
select test.login(:DANA);
select test.put('hl', (request_po_line(test.v('hw'), 'repair', 380, 'Replace failed condenser fan motor')).id);
select approval_link(test.v('hl')) as htok \gset
select test.blocked($$select approval_link((select id from po_lines where status = 'pending' and work_order_id in (select id from work_orders where customer_id = '20000000-0000-0000-0000-000000000001') limit 1))$$,
  null, 'no homeowner links for customers who have their own logins');
reset role; set role anon;
select test.ok((select link_quote(:'htok')->>'audience' = 'homeowner'), 'homeowner opens the quote without an account');
select test.blocked($$select link_decide('00000000-0000-0000-0000-000000000000', true)$$, 'not valid', 'a made-up link does nothing');
select test.ok((select (link_decide(:'htok', true)->>'status') = 'approved'), 'homeowner taps Approve');
select test.ok((select (link_decide(:'htok', false, 'changed my mind')->>'already')::boolean), 'a second tap changes nothing');
reset role; set role authenticated;
select test.login(:DANA);
select test.ok((select status = 'approved' and customer_decided_via = 'link' from po_lines where id = test.v('hl')), 'office sees: approved by the homeowner, by link');
select test.ok((select used_from is not null or used_at is not null from approval_links where po_line_id = test.v('hl')), 'the tap is logged');


\echo '=== 21. Tech app: live meter, stop point, quotes from hours + parts, emergency limit, no running over'
set role authenticated;
select test.login(:MARIA);
select test.put('tw', (create_work_order(:S121, (select id from issue_types where code='self_contained_down'), 'Produce cooler warm')).id);
select test.login(:PAT);
select test.put('tv', (assign_work_order(test.v('tw'), :MIKE)).id);
reset role; select test.backdate(test.v('tv'), 200); set role authenticated;
select test.login(:MIKE);
select test.ok((select jsonb_array_length(tech_jobs()->'jobs') >= 1), 'tech downloads his jobs for offline use');
select test.ok((select bool_or((j->'wo'->>'id')::uuid = test.v('tw')) from jsonb_array_elements(tech_jobs()->'jobs') j), 'the new job is in the download');
select test.ok((select count(*) = 0 from jsonb_array_elements(tech_jobs()->'jobs') j where j ? 'code'), 'the check-in code is never sent to the tech');
select from tech_start(test.v('tv'), now() - interval '190 minutes', 47.95, -97.10);
select from tech_arrive(test.v('tv'), now() - interval '100 minutes', 47.8936, -97.0632);
reset role; select sum(amount) as tdiag from po_lines where work_order_id = test.v('tw') and kind = 'diagnosis' \gset
set role authenticated; select test.login(:MIKE);
select test.ok((select (job_meter(test.v('tw'))->>'limit')::numeric = (:tdiag)::numeric), 'meter limit = the approved diagnosis ($125, more after hours)');
select '      meter: ' || job_meter(test.v('tw'))::text;
select test.ok((select (job_meter(test.v('tw'))->>'stop_at')::numeric < (:tdiag)::numeric * 0.8), 'small limit: stop point is earlier than 80% (room for the wait + wrap-up)');
select test.ok((select job_meter(test.v('tw'))->>'state' in ('stop','over')), '100 min on site at $125/hr: the meter says STOP');
reset role;
select test.ok(meter_watch() >= 1, 'server check catches it even with the phone off');
set role authenticated;
select test.ok((select count(*) >= 1 from notifications where type = 'guardrail_flag' and message like 'Job #%STOP%'), 'tech is told to stop');
select test.blocked($$select set_part_used(test.v('tv'), '40000000-0000-0000-0000-000000000005', 1)$$, 'over the approved', 'a part that would cross the limit cannot be added');
reset role; select round(125 * case when is_after_hours(:S121, now()) then 1 + after_hours_pct / 100 else 1 end, 2) as trate from platform_settings \gset
set role authenticated; select test.login(:MIKE);
select test.put('tq', (request_quote(test.v('tw'), 1.5, '[{"part_id":"40000000-0000-0000-0000-000000000005","qty":1}]', 'Contactor burned; replace and test')).id);
select test.ok((select amount = round(1.5 * :trate, 2) + 58 and (breakdown->>'labor')::numeric = round(1.5 * :trate, 2) from po_lines where id = test.v('tq')),
  'quote = 1.5 h × $125 (after-hours rate at night) + contactor $58, with labor and parts shown separately');
select '      ' || po_label(work_order_id, seq) || ' not to exceed $' || amount || '  ' || breakdown::text from po_lines where id = test.v('tq');
select test.login(:MARIA);
select from decide_po_line(test.v('tq'), true);
select test.login(:MIKE);
select test.ok((select (set_part_used(test.v('tv'), '40000000-0000-0000-0000-000000000005', 1)).id is not null), 'after approval the part goes in');

\echo '    -- emergency, pre-approved up to the store''s emergency limit'
reset role;
update sites set emergency_limit = 1500 where id = :S121;
set role authenticated;
select test.login(:MARIA);
select test.put('ew', (create_work_order(:S121, (select id from issue_types where code='wi_cooler_down'), 'Walk-in cooler at 52°F', null, 1::smallint)).id);
select test.login(:PAT);
select test.put('ev', (assign_work_order(test.v('ew'), :LUIS)).id);
select test.login(:LUIS);
select from tech_start(test.v('ev')); select from tech_arrive(test.v('ev'), null, 47.8936, -97.0632);
select test.ok((select job_meter(test.v('ew'))->>'emergency_limit' = '1500.00'), 'meter shows the emergency limit');
select test.put('el', (request_quote(test.v('ew'), 3, '[{"part_id":"40000000-0000-0000-0000-000000000001","qty":1}]', 'Condenser fan motor seized — replace now, product at risk')).id);
select test.ok((select status = 'approved' and emergency_preapproved from po_lines where id = test.v('el')), 'emergency letter within $1,500 goes ahead at once');
select test.login(:MARIA);
select test.ok((select count(*) >= 1 from notifications where message like 'EMERGENCY call%pre-approved emergency limit%'), 'store told immediately');
select test.login(:LUIS);
select test.put('el2', (request_quote(test.v('ew'), 4, '[{"part_id":"40000000-0000-0000-0000-000000000001","qty":2}]', 'Second condenser also failing')).id);
select test.ok((select status = 'pending' and not emergency_preapproved from po_lines where id = test.v('el2')), 'above the emergency limit it needs a person to approve');

\echo '=== 22. Tech at the door: first, second, third person in the store''s own order'
set role authenticated;
select test.login(:SAM);
select test.put('dw', (create_work_order(:S114, (select id from issue_types where code='self_contained_down'), 'Door test')).id);
select test.login(:PAT);
select test.put('dv', (assign_work_order(test.v('dw'), :MIKE)).id);
reset role; select test.backdate(test.v('dv'), 30); set role authenticated;
select test.login(:MIKE);
select from tech_start(test.v('dv'), now() - interval '25 minutes', 47.95, -97.10);
select from tech_arrive(test.v('dv'), now() - interval '2 minutes', 47.9101, -97.0491);
reset role;
select checkin_watch();
create temp view door as select p.full_name who, n.message from notifications n join profiles p on p.id = n.user_id
  where n.work_order_id = test.v('dw') and n.dedupe_key like 'door:%';
select test.ok((select count(*) = 1 from door where who = 'Sam Store Manager') and (select count(*) = 0 from door where who <> 'Sam Store Manager'),
  'minute 2: only the first person (store manager) is alerted');
create or replace function test.wait_more(p_visit uuid, p_mins int) returns void language plpgsql as $$
begin perform _allow_internal(true); update visits set arrived_at = arrived_at - make_interval(mins => p_mins) where id = p_visit; perform _end_internal(); end $$;
select test.wait_more(test.v('dv'), 4);
select checkin_watch();
select test.ok((select count(*) >= 1 from door where who = 'Maria Lopez') and (select count(*) >= 1 from door where who = 'Doug Reed'),
  'minute 6: no answer → second person (maintenance manager) and her backup (director)');
select '      ' || who || ': ' || message from door where who = 'Maria Lopez';
select test.ok((select count(*) = 0 from notifications n join profiles p on p.id = n.user_id where n.work_order_id = test.v('dw')
  and p.contractor_id is not null and n.dedupe_key like 'door:%'), 'contractor office not bothered yet');
select test.wait_more(test.v('dv'), 5);
select checkin_watch();
select test.ok((select count(*) >= 1 from notifications n join profiles p on p.id = n.user_id where n.work_order_id = test.v('dw')
  and p.contractor_id is not null and n.dedupe_key = 'door:' || test.v('dv') || ':office'), 'minute 11: third person + contractor office alerted');
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('dw') and flag = 'checkin_unverified'), 'the wait is flagged on the call');
select checkin_watch();
select test.ok((select count(*) = 1 from door where who = 'Sam Store Manager'), 'each person is alerted once per step, not every minute');

\echo '=== 23. Phone clock: checked at every sync; offline times can''t go before the last contact'
set role authenticated;
select test.login(:LUIS);
select test.ok((select (device_hello(now() + interval '1 second')->>'ok')::boolean), 'clock within 2 minutes: fine');
select test.ok((select not (device_hello(now() - interval '25 minutes')->>'ok')::boolean), 'clock 25 min slow: tech is told');
select test.login(:DANA);
select test.ok((select count(*) = 1 from notifications where message like 'Luis Ortega''s phone clock is 25 min slow%'), 'office is told (once a day)');
select test.login(:LUIS);
select from device_hello(now());
select test.ok((select start_at >= now() - interval '1 minute' from clock('in', now() - interval '3 hours')),
  'a time from before the phone''s last contact is moved up to that contact (a clock set back can''t move times earlier)');
select test.ok((select start_at = now() from clock('break_start', now())), 'normal times are kept as they happened');
select from clock('out');
\echo '=== 24. Location settings: guest Wi-Fi only for the store and the tech on the job'
set role authenticated;
select test.login(:SAM);
select test.blocked($$select set_site_settings('30000000-0000-0000-0000-000000000001', 1500, 'Northside-Guest', 'cooler2024')$$, 'permission', 'a store manager who is not an admin cannot change settings');
select test.login(:DOUG);
select from set_site_settings('30000000-0000-0000-0000-000000000001', 1500, 'Northside-Guest', 'cooler2024');
select test.ok((select ssid = 'Northside-Guest' from site_wifi where site_id = :S114), 'director (admin) sets the guest Wi-Fi and emergency limit');
select test.login(:SAM);
select test.ok((select count(*) = 1 from site_wifi where site_id = :S114), 'store staff can see it');
select test.login(:MIKE);
select test.ok((select count(*) = 1 from site_wifi where site_id = :S114), 'the tech with an open job there can see it');
select test.login(:RIVAL);
select test.ok((select count(*) = 0 from site_wifi), 'another contractor cannot');
select test.login(:DANA);
select test.ok((select count(*) = 0 from site_wifi), 'not even the contractor office — only the tech on the job');

\echo '=== 25. Close out without photos/details: office override code, or owner; reason required; store sees it'
set role authenticated;
select test.login(:MARIA);
select test.put('ow', (create_work_order(:S121, (select id from issue_types where code='wi_cooler_down'), 'Override test')).id);
select test.login(:PAT);
select test.put('ov', (assign_work_order(test.v('ow'), :LUIS)).id);
select test.login(:LUIS);
select from tech_start(test.v('ov')); select from tech_arrive(test.v('ov'), null, 47.8936, -97.0632);
select test.ok((select (tech_finish_visit(test.v('ov'), 'completed')->>'ok')::boolean = false), 'normally: no photos / equipment → cannot complete');
select test.blocked($$select tech_closeout_override(test.v('ov'), 'Problem fixed before arrival', 'Store reset the breaker, unit running fine at 36F')$$,
  'Call your office', 'a tech (not the owner) needs an office code');
select test.login(:PAT);
select test.blocked($$select issue_closeout_code(test.v('ov'), 'x')$$, 'Note what', 'office must note what the tech said');
select test.put('oc', null);
create temp table oc_tmp as select issue_closeout_code(test.v('ov'), 'Luis says the store reset the breaker; unit running') as code;
select test.login(:LUIS);
select test.blocked($$select tech_closeout_override(test.v('ov'), 'Problem fixed before arrival', 'Store reset the breaker, unit running fine at 36F', '000000')$$,
  'not right', 'a wrong override code does nothing');
select test.ok((select (tech_closeout_override(test.v('ov'), 'Problem fixed before arrival', 'Store reset the breaker, unit running fine at 36F',
  (select code from oc_tmp))->>'ok')::boolean), 'with the office code and a reason, the visit closes');
select test.ok((select (tech_closeout_override(test.v('ov'), 'x', 'sent again when the phone reconnects', (select code from oc_tmp))->>'already')::boolean), 'sending it twice (phone resync) changes nothing');
select test.login(:PAT);
select test.ok((select used_at is not null and method = 'office_code' from closeout_overrides where visit_id = test.v('ov')), 'office sees the code was used');
select test.login(:MARIA);
select test.ok((select status = 'completed' and work_summary like '%Closed out without full documentation%Approved by Pat Dispatch (office, by phone)%'
  from work_orders where id = test.v('ow')), 'store sees the reason and who approved it');
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('ow') and flag = 'closeout_override' and visible_to_customer), 'flagged for the store');
select test.ok((select count(*) = 0 from closeout_overrides), 'the store never sees the codes');
select '      ' || work_summary from work_orders where id = test.v('ow');
reset role;
update profiles set is_org_admin = true where id = :LUIS;   -- pretend Luis owns a one-man shop
set role authenticated;
select test.login(:MARIA);
select test.put('ow2', (create_work_order(:S121, (select id from issue_types where code='wi_cooler_down'), 'Owner override test')).id);
select test.login(:PAT);
select test.put('ov2', (assign_work_order(test.v('ow2'), :LUIS)).id);
select test.login(:LUIS);
select from tech_start(test.v('ov2')); select from tech_arrive(test.v('ov2'), null, 47.8936, -97.0632);
select test.ok((select tech_closeout_override(test.v('ov2'), 'Store closed / no access', 'Store locked, no one answered the door or phone for 20 min')->>'method' = 'owner'),
  'a sole owner approves their own override (the app asks for their password first)');
reset role;
update profiles set is_org_admin = false where id = :LUIS;
set role authenticated;

\echo '=== 26. Time Verify: the store invites its plumber; sign-in by link (no password)'
set role authenticated;
select test.login(:SAM);
select test.blocked($$select invite_contractor('Prairie Plumbing', 'Pete Prairie', 'pete@prairie.test', null, '{3}')$$,
  'permission', 'a store manager (not admin) cannot invite contractors');
select test.login(:DOUG);
create temp table tv as select (invite_contractor('Prairie Plumbing', 'Pete Prairie', 'pete@prairie.test', '701-555-0100', '{3}')->>'token')::uuid as tok;
reset role;
grant select on tv to anon, authenticated;
set role anon;
select test.ok((select join_info((select tok from tv))->>'invited_by' = 'Northside Grocers (demo)'), 'the link page shows who invited them (no login needed)');
select test.ok((select join_redeem((select tok from tv))->>'email' = 'pete@prairie.test'), 'opening the link makes the login and signs the phone in');
select test.blocked($$select join_redeem((select tok from tv))$$, 'already used', 'the link works once');
select test.ok((select join_info(gen_random_uuid())->>'ok' = 'false'), 'a made-up link is rejected');
reset role;
select test.put('PETE', (select profile_id from join_links where token = (select tok from tv)));
select test.put('PRAIRIE', (select contractor_id from join_links where token = (select tok from tv)));
select test.ok((select is_org_admin and is_technician and can_bill from profiles where id = test.v('PETE')), 'the owner can run the office and go on calls');
select test.ok((select mode = 'verify' from customer_contractors where contractor_id = test.v('PRAIRIE')), 'the relationship is Time Verify');
set role authenticated;
select test.login(test.v('PETE'));
create temp table tv2 as select add_team_member('Tony Tech', '701-555-0101') as tok;
reset role; grant select on tv2 to anon, authenticated; set role anon;
select test.ok((select join_redeem((select tok from tv2))->>'email' like '%@users.servicepro.app'), 'a tech added by phone number gets a login without an email');
reset role;
select test.put('TONY', (select profile_id from join_links where token = (select tok from tv2)));
select test.ok((select is_technician and not is_org_admin from profiles where id = test.v('TONY')), 'Tony is a technician');
set role authenticated;
select test.login(:LUIS);
select test.blocked($$select add_team_member('X Y', '1')$$, 'owner', 'a tech cannot add people');
select test.login(:DOUG);
create temp table tv3 as select (invite_contractor('Imposter Co', 'Someone', 'luis@arcticair.demo')->>'token')::uuid as tok;
reset role; grant select on tv3 to anon; set role anon;
select test.blocked($$select join_redeem((select tok from tv3))$$, 'already has a login', 'an invite cannot take over an existing login');
set role authenticated;

\echo '=== 27. Store opens a PO call; routed by trade; contractor alerted'
select test.login(:MARIA);
select test.put('tw', (open_po_call(:S121, (select id from issue_types where code='drain_backup'), 'Floor drain by the deli backing up',
  'NS-4471', 600)).id);
select test.ok((select contractor_id = test.v('PRAIRIE') and mode = 'verify' and store_po_number = 'NS-4471' and nte = 600
  and accept_due_at between created_at + interval '239 minutes' and created_at + interval '241 minutes' from work_orders where id = test.v('tw')),
  'plumbing goes to the plumber, as Time Verify, with the store''s PO, $600 limit, accept within 4 hours');
select test.ok((select count(*) = 0 from po_lines where work_order_id = test.v('tw')), 'no approval letters on Time Verify calls');
select test.blocked($$select open_po_call('30000000-0000-0000-0000-000000000002', (select id from issue_types where code='drain_backup'), 'again', 'NS-4471')$$,
  'already on an open call', 'the same PO number cannot be used twice');
select test.put('tfull', (open_po_call(:S121, (select id from issue_types where code='wi_cooler_down'), 'Walk-in warm')).id);
select test.ok((select contractor_id = :ARCTIC and mode = 'full' and store_po_number is null from work_orders where id = test.v('tfull')),
  'refrigeration still goes to Arctic Air, full mode');
select test.blocked($$select open_po_call('30000000-0000-0000-0000-000000000002', (select id from issue_types where code='wi_cooler_down'), 'x', null, 500)$$,
  'approved amounts', 'a not-to-exceed only applies to Time Verify contractors');
select test.login(test.v('PETE'));
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('tw') and type = 'new_call' and message like '%PO call #%NS-4471%Please accept by%'),
  'the plumber''s office is alerted');
select test.ok((select jsonb_array_length(tech_jobs()->'open_calls') = 1), 'the call shows on the techs'' phones as one anyone can take');
select test.ok((select (tech_jobs()->'open_calls'->0->>'po_number') = 'NS-4471'), 'with the store''s PO number');

\echo '=== 28. Not accepted in time → store told; office accepts with a time window'
reset role;
do $$ begin perform _allow_internal(); update work_orders set accept_due_at = now() - interval '1 minute' where id = test.v('tw'); perform _end_internal(); end $$;
select test.ok(accept_watch() >= 1, 'the watcher finds the late call');
set role authenticated;
select test.login(:MARIA);
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('tw') and message like '%has NOT accepted call%Phone: 701-555-0100%'),
  'the store is told, with the contractor''s phone number');
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('tw') and flag = 'not_accepted' and resolved_at is null), 'flagged on the call');
select test.login(test.v('PETE'));
select from accept_call(test.v('tw'), 'scheduled', now() + interval '1 hour', now() + interval '3 hours');
select test.login(:MARIA);
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('tw') and type = 'assigned' and message like 'Prairie Plumbing accepted call%scheduled%'),
  'store sees "accepted — scheduled …"');
select test.ok((select count(*) = 0 from guardrail_flags where work_order_id = test.v('tw') and flag = 'not_accepted' and resolved_at is null), 'flag cleared');
select test.login(:SAM);
select test.blocked($$select accept_call((select test.v('tw')))$$, 'contractor office', 'a store cannot accept for the contractor');

\echo '=== 29. Tech: I''m going (one tech only) → I''m here → code → parts run → Leaving'
select test.login(test.v('TONY'));
select test.put('tv', (tech_claim_call(test.v('tw'), null, 47.92, -97.03)).id);
select test.ok((select status = 'en_route' and started_at is not null from visits where id = test.v('tv')), 'Tony is on the way (one tap)');
select test.ok((select (tech_claim_call(test.v('tw'))).id = test.v('tv')), 'tapping again changes nothing');
select test.login(test.v('PETE'));
select test.blocked($$select tech_claim_call((select test.v('tw')))$$, 'Already taken — Tony Tech', 'no double dispatch: Pete sees Tony has it');
select test.ok((select jsonb_array_length(tech_jobs()->'open_calls') = 0), 'it leaves everyone else''s list');
select test.login(:LUIS);
select test.blocked($$select tech_claim_call((select test.v('tw')))$$, 'not for your company', 'another company''s tech cannot take it');
select test.blocked($$select tech_claim_call((select test.v('tfull')))$$, 'dispatcher', 'full-mode jobs are still assigned by dispatch');
select test.login(test.v('TONY'));
select from tech_arrive(test.v('tv'), null, 47.8936, -97.0632);
select test.ok((select (tech_leave(test.v('tv'), 'completed')->'missing'->0->>'item') = 'checkin'), 'cannot leave before checking in with the store');
reset role; create temp table vc as select code from visit_codes where visit_id = test.v('tv'); grant select on vc to authenticated; set role authenticated;
select test.ok((select (tech_checkin(test.v('tv'), 'code', (select code from vc))->>'verified')::boolean),
  'check-in with the store''s code');
select from tech_parts_run(test.v('tv'), 'leave', 'a0000000-0000-0000-0000-0000000000f1', null, null, 47.8936, -97.0632);
select test.ok((select (tech_leave(test.v('tv'), 'completed')->'missing'->0->>'item') = 'parts_run'), 'cannot leave while on a parts run');
select from tech_parts_run(test.v('tv'), 'at_supplier', 'a0000000-0000-0000-0000-0000000000f1', 'Ferguson', null, 47.90, -97.05);
select from tech_parts_run(test.v('tv'), 'back', 'a0000000-0000-0000-0000-0000000000f1', null, null, 47.8936, -97.0632);
select test.ok((select (tech_parts_run(test.v('tv'), 'back', 'a0000000-0000-0000-0000-0000000000f1')->>'returned_at') is not null), 'parts run steps can be resent safely');
select test.ok((select tech_leave(test.v('tv'), 'completed', 'Snaked drain, replaced trap')->>'ok')::boolean, 'Leaving — done (no photos needed)');
select test.ok((select status = 'completed' and invoice_due_at is not null from work_orders where id = test.v('tw')), 'call is complete; invoice due date set');
select test.ok((select count(*) = 0 from platform_fees where work_order_id = test.v('tw')), 'no per-call fee on Time Verify');
-- realistic times: left the shop 9:00, arrived 9:30, parts run 10:30–11:10, left 11:30
reset role;
do $$ begin
perform _allow_internal(true);
update visits set started_at = now() - interval '150 minutes', arrived_at = now() - interval '120 minutes',
       completed_at = now(), departed_at = now(), checkin_at = now() - interval '119 minutes' where id = test.v('tv');
update parts_runs set left_at = now() - interval '60 minutes', at_supplier_at = now() - interval '45 minutes', returned_at = now() - interval '20 minutes'
 where id = 'a0000000-0000-0000-0000-0000000000f1';
perform _end_internal();
end $$;
set role authenticated;
select test.login(:MARIA);
select test.ok((select (verified_hours(test.v('tw'))->>'onsite_h')::numeric = 1.33 and (verified_hours(test.v('tw'))->>'travel_h')::numeric = 0.5
  and (verified_hours(test.v('tw'))->>'parts_run_h')::numeric = 0.67 and (verified_hours(test.v('tw'))->>'verified_h')::numeric = 2.5),
  'verified: 1.33 h on site + 0.5 h travel + 0.67 h parts run = 2.5 h');
select '      ' || (verified_hours(test.v('tw')) - 'visits')::text;

\echo '=== 30. Invoice check: billed vs verified hours'
select test.login(test.v('PETE'));
select test.ok((select (submit_invoice(test.v('tw'), 'INV-881', 540, 3.5)->>'unexplained_h')::numeric = 1.0), 'bills 3.5 h; 2.5 verified → 1 h not explained');
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('tw') and flag = 'invoice_unexplained' and resolved_at is null and visible_to_customer),
  'the store sees the unexplained hour');
select test.blocked($$select submit_invoice((select test.v('tw')), 'INV-881', 540, 3.5, 1)$$, 'what the other hours', 'extra hours need a reason');
select test.ok((select (submit_invoice(test.v('tw'), 'INV-881', 640, 3.5, 1, 'Shop: rebuilt the trap assembly')->>'all_verified')::boolean),
  'contractor explains the hour (shop work) → all hours accounted for');
select test.ok((select count(*) = 0 from guardrail_flags where work_order_id = test.v('tw') and flag = 'invoice_unexplained' and resolved_at is null), 'flag cleared');
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('tw') and flag = 'invoice_over_nte' and resolved_at is null),
  '$640 is over the store''s $600 limit → flagged');
select test.ok((select status = 'invoiced' from work_orders where id = test.v('tw')), 'call shows invoiced');
select test.login(:SAM);
select test.blocked($$select submit_invoice((select test.v('tw')), 'X', 1, 1)$$, 'Not allowed', 'a store manager without billing rights cannot touch invoices');
select test.login(:MARIA);
select test.blocked($$select submit_invoice((select test.v('tw')), 'X', 1, 1)$$, 'contractor already entered', 'the store cannot overwrite the contractor''s invoice');
select test.ok((select message like 'Invoice INV-881%' from notifications where work_order_id = test.v('tw') and type = 'billing_due' order by created_at desc limit 1),
  'the store is told what was billed vs verified');
select test.ok((select status = 'approved' from store_review_invoice(test.v('tw'), true)), 'store approves');
select test.login(test.v('PETE'));
select test.blocked($$select submit_invoice((select test.v('tw')), 'INV-881', 1, 1)$$, 'already approved', 'an approved invoice is final');
select test.login(:DOUG);
select from set_contractor_terms(test.v('PRAIRIE'), null, 'no');
select test.ok((select (verified_hours(test.v('tw'))->>'travel_counted_h')::numeric = 0 and (verified_hours(test.v('tw'))->>'verified_h')::numeric = 2.0),
  'store setting "We don''t pay travel" → travel is shown but not counted');
select from set_contractor_terms(test.v('PRAIRIE'), null, 'yes');

\echo '=== 31. A call the contractor took by phone: the store confirms it'
select test.login(test.v('PETE'));
select test.put('tp', (enter_phone_call(:S114, (select id from issue_types where code='water_leak'), 'Leak under the 3-comp sink', 'Sam', '701-555-0199')).id);
select test.ok((select source = 'contractor' and accepted_at is not null and store_confirmed_at is null from work_orders where id = test.v('tp')),
  'entered by the contractor: accepted, not yet confirmed by the store');
select test.login(:SAM);
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('tp') and flag = 'call_unconfirmed' and resolved_at is null), 'the store sees it as unconfirmed');
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('tp') and message like '%requested by Sam%confirm%'), 'the store is asked to confirm');
select test.ok((select store_po_number = 'NS-4502' from store_confirm_call(test.v('tp'), true, 'NS-4502')), 'Sam confirms and adds the store''s PO number');
select test.ok((select count(*) = 0 from guardrail_flags where work_order_id = test.v('tp') and flag = 'call_unconfirmed' and resolved_at is null), 'flag cleared');
select test.login(test.v('PETE'));
select test.put('tp2', (enter_phone_call(:S114, (select id from issue_types where code='no_hot_water'), 'No hot water in restrooms', 'Kyle (night stocker)')).id);
select test.login(:SAM);
select from store_confirm_call(test.v('tp2'), false, null, 'Kyle is not authorized to order service');
select test.ok((select store_disputed from work_orders where id = test.v('tp2')), 'or the store disputes it — on record for both sides');

\echo '=== 32. Store: "The tech is here but didn''t check in"'
select test.login(test.v('TONY'));
select test.put('tv2', (tech_claim_call(test.v('tp'))).id);
select test.login(:SAM);
select test.ok((select store_tech_here(test.v('tp'))->>'technician' = 'Tony Tech'), 'Sam presses "Tech is here"');
select test.ok((select status = 'on_site' and arrival_source = 'store' and arrived_at is not null from visits where id = test.v('tv2')),
  'arrival recorded from the store side (the tech is paid from now)');
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('tp') and flag = 'arrival_by_store'), 'flagged for the contractor');
select test.login(test.v('TONY'));
select test.ok((select count(*) = 1 from notifications where user_id = test.v('TONY') and message like 'The store says you are at%'), 'Tony is told to check in');
select test.ok((select status = 'on_site' from tech_arrive(test.v('tv2'), null, 47.91, -97.049)), 'his late "I''m here" tap is harmless');
reset role;
do $$ begin perform _allow_internal(true); update visits set arrived_at = now() - interval '6 minutes' where id = test.v('tv2'); perform _end_internal(); end $$;
select test.ok(checkin_watch() >= 1, 'the door alarm runs while no code has been entered');
set role authenticated;
select test.login(:MARIA);
select test.put('tn', (open_po_call(:S121, (select id from issue_types where code='water_leak'), 'Leak at mop sink')).id);
select test.ok((select accept_due_at < created_at + interval '16 minutes' from work_orders where id = test.v('tn')), 'emergency problem → must be accepted within 15 minutes');
select test.ok((select (store_tech_here(test.v('tn'))->>'no_visit')::boolean), 'tech here but nobody took the call in the app → office told');

\echo '=== 33. QR sticker on the unit + store PIN'
select test.login(:DOUG);
select from set_report_pin(:S114, '2468');
select test.blocked($$select set_report_pin('30000000-0000-0000-0000-000000000001', '12')$$, '4 to 6 digits', 'PIN must be 4–6 digits');
select test.login(:SAM);
select test.blocked($$select * from site_report_pins$$, 'permission denied', 'nobody can read the PIN (not even a hash)');
reset role;
create temp table qrt as select (select qr_token from equipment where id = '80000000-0000-0000-0000-000000000001') t1,
  (select qr_token from equipment where id = '80000000-0000-0000-0000-000000000002') t2,
  (select id from issue_types where code = 'wi_freezer_down') fz;
grant select on qrt to anon;
set role anon;
select test.ok((select qr_info((select t1 from qrt))->>'unit' like 'Walk-in freezer%'),
  'scanning the sticker shows the unit, no login');
select test.ok((select qr_report((select t1 from qrt), '1111', null, 'Freezer warm', 'Jen')->>'error' like 'Wrong store PIN%'), 'wrong PIN does nothing');
select test.ok((select qr_report((select t1 from qrt), '2468',
  (select fz from qrt), 'Freezer at 20F', 'Jen (night crew)')->>'contractor' = 'Arctic Air Mechanical (demo)'),
  'right PIN → call opened to the refrigeration contractor');
select test.blocked($$select qr_report((select t1 from qrt), '2468', null, 'Freezer still warm', 'Bob')$$,
  'already reported', 'a second scan within 2 hours does not make a duplicate call');
reset role;
select test.ok((select reported_by_name = 'Jen (night crew)' and source = 'qr' and equipment_id = :FREEZER from work_orders where reported_by_name is not null order by created_at desc limit 1),
  'the call knows which unit and who reported it');
select test.ok((select count(*) = 1 from guardrail_flags g join work_orders w on w.id = g.work_order_id where w.source = 'qr' and g.flag = 'repeat_call'),
  'repeat-call flag: this freezer had a call in the last 30 days');
select '      ' || g.description from guardrail_flags g join work_orders w on w.id = g.work_order_id where w.source = 'qr' and g.flag = 'repeat_call';
set role anon;
select test.ok((select qr_report((select t2 from qrt), '0000', null, 'x', 'y')->>'ok' = 'false'), 'wrong PIN 1');
select test.ok((select qr_report((select t2 from qrt), '0000', null, 'x', 'y')->>'ok' = 'false'), 'wrong PIN 2');
select test.ok((select qr_report((select t2 from qrt), '0000', null, 'x', 'y')->>'ok' = 'false'), 'wrong PIN 3');
select test.ok((select qr_report((select t2 from qrt), '0000', null, 'x', 'y')->>'ok' = 'false'), 'wrong PIN 4');
select test.ok((select qr_report((select t2 from qrt), '0000', null, 'x', 'y')->>'ok' = 'false'), 'wrong PIN 5');
select test.blocked($$select qr_report((select t2 from qrt), '2468', null, 'Condenser loud', 'Bob')$$,
  'Too many', 'after 5 wrong PINs the sticker locks for 15 minutes');

\echo '=== 34. Decline → store sends it to another contractor'
set role authenticated;
select test.login(:MARIA);
select test.put('td', (open_po_call(:S121, (select id from issue_types where code='no_hot_water'), 'No hot water, kitchen')).id);
select test.login(test.v('PETE'));
select from decline_call(test.v('td'), 'Booked solid until Monday');
select test.login(:MARIA);
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('td') and message like '%can''t take call%Booked solid%'), 'store is told right away');
select test.ok((select contractor_id = :ARCTIC and mode = 'full' from reroute_call(test.v('td'), :ARCTIC)), 'store sends it to Arctic Air instead');
select test.login(test.v('PETE'));
select test.ok((select count(*) = 0 from work_orders where id = test.v('td')), 'Prairie no longer sees it');

\echo '=== 35. Store PO log'
select test.login(:MARIA);
select test.ok((select count(*) >= 4 from po_log where contractor_name = 'Prairie Plumbing'), 'every call is in the PO log');
select test.ok((select invoice_total = 640 and hours_unexplained = 0 and 'invoice_over_nte' = any(flags) from po_log where id = test.v('tw')),
  'with invoice total, hours check and flags');
select '      ' || concat_ws(' | ', po_number, site_name, problem_type, status, invoice_total, hours_billed, hours_verified, array_to_string(flags, ',')) from po_log where id = test.v('tw');
select test.login(:RIVAL);
select test.ok((select count(*) = 0 from po_log where customer_id = '20000000-0000-0000-0000-000000000001'), 'another contractor sees none of it');

\echo '=== 36. Billing: flat per location for Time Verify stores; contractor free'
reset role;
select monthly_billing_run((current_date + interval '1 month')::date);   -- this month's statement was already paid above
select test.ok((select subscription_fees = 25 * (select count(*) from sites where customer_id = '20000000-0000-0000-0000-000000000001')
  from monthly_statements where org_kind = 'customer' and org_id = '20000000-0000-0000-0000-000000000001' and billing_month = date_trunc('month', current_date + interval '1 month')::date),
  'Northside: $25 × each location');
select test.ok((select count(*) = 0 from monthly_statements where org_kind = 'contractor' and org_id = test.v('PRAIRIE')), 'Prairie Plumbing pays nothing');

\echo '=== 37. Alerts go out to phones and email (sender with its key)'
set role anon;
select test.blocked($$select outbox_take('wrong')$$, 'Not allowed', 'the sender needs the key');
reset role;
create temp table ob as select outbox_take((select value from app_secrets where name = 'outbox'), 200) as j;
select test.ok((select jsonb_array_length(j) > 0 from ob), 'waiting alerts are handed over once');
select test.ok((select count(*) = 0 from notifications where sent_at is null and id in (select (x->>'id')::uuid from ob, jsonb_array_elements(j) x)), 'and marked sent');
set role authenticated;
select test.login(test.v('TONY'));
select from save_push_subscription('https://push.example/abc', 'key', 'auth');
select test.ok((select count(*) = 1 from push_subscriptions), 'a phone can sign up for alerts');
reset role;

\echo '=== 38. Every trip announced to the store; who is coming / who is inside; missed windows; unexpected visitors'
set role authenticated;
select test.login(:MARIA);
select test.put('t3', (open_po_call(:S121, (select id from issue_types where code='drain_backup'), 'Hand sink slow', 'NS-5001')).id);
select test.login(test.v('TONY'));
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('t3') and type = 'new_call' and message like 'New call #%Take it with%'),
  'the techs are alerted to the new call too');
select test.blocked($$select schedule_trip((select test.v('t3')), (select test.v('TONY')), now() + interval '1 hour')$$, 'office', 'a tech (not office) cannot schedule trips');
select test.login(test.v('PETE'));
select test.ok((select count(*) = 0 from notifications where work_order_id = test.v('t3') and message like '%Take it with%'), 'the owner gets the office alert only, not twice');
select test.put('tv3', (schedule_trip(test.v('t3'), test.v('TONY'), now() + interval '1 hour', now() + interval '3 hours', 'Bring the snake')).id);
select test.ok((select status = 'assigned' and scheduled_start is not null and scheduled_by = test.v('PETE') from visits where id = test.v('tv3')), 'trip scheduled for Tony');
select test.ok((select status = 'assigned' and accepted_at is not null from work_orders where id = test.v('t3')), 'scheduling also accepts the call');
select test.login(:MARIA);
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('t3') and type = 'assigned' and message like 'Tony Tech (Prairie Plumbing) is scheduled for call #%NS-5001%. Bring the snake'),
  'the store is told who is coming and when');
select test.ok((select count(*) = 1 from visit_codes where visit_id = test.v('tv3')), 'the trip has its own check-in code on the store screen');
select test.login(test.v('TONY'));
select test.ok((select count(*) = 1 from notifications where user_id = test.v('TONY') and message like 'New job #%. Bring the snake'), 'Tony gets it on his phone');
select test.login(test.v('PETE'));
select test.blocked($$select tech_claim_call((select test.v('t3')))$$, 'scheduled for it', 'nobody else can take a trip scheduled for Tony');
select test.login(test.v('TONY'));
select test.ok((select (tech_claim_call(test.v('t3'))).status = 'en_route'), 'Tony taps I''m going on his scheduled trip → on the way');
select test.login(test.v('PETE'));
select test.blocked($$select schedule_trip((select test.v('t3')), (select test.v('TONY')), now() + interval '1 day')$$, 'already on the way', 'no second trip while one is under way');

-- missed window
select test.login(:MARIA);
select test.put('t4', (open_po_call(:S121, (select id from issue_types where code='no_hot_water'), 'No hot water, mop sink')).id);
select test.login(test.v('PETE'));
select test.put('tv4', (schedule_trip(test.v('t4'), test.v('TONY'), now() + interval '10 minutes', now() + interval '2 hours')).id);
select test.put('tv4b', (schedule_trip(test.v('t4'), test.v('PETE'), now() + interval '20 minutes', now() + interval '2 hours')).id);
select test.ok((select status = 'cancelled' from visits where id = test.v('tv4')), 'rescheduling replaces the trip that hadn''t started');
select test.login(test.v('TONY'));
select test.ok((select count(*) = 1 from notifications where user_id = test.v('TONY') and work_order_id = test.v('t4') and message like '%moved to someone else%'), 'Tony is told it was moved');
reset role;
do $$ begin update visits set scheduled_start = now() - interval '3 hours', scheduled_end = now() - interval '1 hour' where id = test.v('tv4b'); end $$;
select test.ok(trip_watch() >= 1, 'the watcher finds the missed window');
set role authenticated;
select test.login(:MARIA);
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('t4') and flag = 'missed_window' and visible_to_customer), 'flagged on the call');
select test.ok((select count(*) = 1 from notifications where work_order_id = test.v('t4') and message like '%was due at Store #121 by%has not checked in%'), 'the store is told');
reset role;
select test.ok((select missed_alert_at is not null from visits where id = test.v('tv4b')) and trip_watch() = 0, 'told once, not every 5 minutes');

-- morning reminder
set role authenticated;
select test.login(:MARIA);
select test.put('t5', (open_po_call(:S121, (select id from issue_types where code='water_leak'), 'Drip at the ice machine drain')).id);
select test.login(test.v('PETE'));
select test.put('tv5', (schedule_trip(test.v('t5'), test.v('TONY'), now() + interval '5 minutes')).id);
reset role;
select trip_watch();
select test.ok((select (now() at time zone 'America/Chicago')::time < time '06:00'
  or (now() at time zone 'America/Chicago')::date <> ((now() + interval '5 minutes') at time zone 'America/Chicago')::date
  or exists (select 1 from notifications where user_id = test.v('TONY') and message like 'Today: job #%Tap Start driving%')), 'morning reminder for a trip scheduled today');

-- unexpected visitor
set role authenticated;
select test.login(:SAM);
select test.ok((select visitor_name = 'Kyle' from store_unexpected_visitor(:S114, 'Kyle', test.v('PRAIRIE'), null, 'In the back room checking the water heater')),
  'Sam logs someone who showed up unannounced');
select test.login(test.v('PETE'));
select test.ok((select count(*) = 1 from notifications where user_id = test.v('PETE') and message like 'Unscheduled visit at Store #114: Kyle (Prairie Plumbing)%schedule the trip%'),
  'the contractor''s office is told');
select test.ok((select count(*) = 1 from site_visitors), 'the office can see the visitor log for its people');
select test.login(:MARIA);
select test.ok((select count(*) = 1 from notifications where user_id = :MARIA and message like 'Unscheduled visit at Store #114%'), 'the store''s other people are told');
select test.login(:RIVAL);
select test.ok((select count(*) = 0 from site_visitors), 'another contractor sees nothing');

-- no-pay rule + invoice with no recorded visit
select test.login(:DOUG);
select test.ok((select unverified_time = 'no_pay' from set_unverified_rule(test.v('PRAIRIE'), 'no_pay')), 'store sets: time not verified is not paid');
reset role;
do $$ begin perform _allow_internal(true);
  update work_orders set status = 'completed', completed_at = now(), invoice_due_at = now() + interval '7 days' where id = test.v('tp2');
  perform _end_internal(); end $$;
set role authenticated;
select test.login(test.v('PETE'));
select from submit_invoice(test.v('tp2'), 'PP-9', 210, 1.5);
select test.login(:SAM);
select test.ok((select count(*) = 1 from guardrail_flags where work_order_id = test.v('tp2') and flag = 'no_recorded_visit'
  and description like '%no visit was recorded%Store rule: time not verified in Service Call Proof is not paid.'), 'invoice with no recorded visit is flagged, with the store''s rule');
select test.login(:DOUG);
select from set_unverified_rule(test.v('PRAIRIE'), 'review');

-- terms accepted when the contractor signed in from the invite
reset role;
select test.ok((select terms_accepted_at is not null from customer_contractors where contractor_id = test.v('PRAIRIE')), 'the contractor accepted the store''s terms by signing in from the invite');
set role anon;
select test.ok((select join_info((select tok from tv))->'terms'->>'unverified_time' = 'review'), 'the invite page shows the store''s terms');

-- contractor record
set role authenticated;
select test.login(:MARIA);
select test.ok((select (r->>'calls')::int >= 5 and (r->>'missed_windows')::int >= 1 and (r->>'unscheduled_visits')::int = 1 and (r->>'invoices')::int >= 1
  from contractor_record(test.v('PRAIRIE')) r), 'the store sees the contractor''s record');
select '      ' || contractor_record(test.v('PRAIRIE'))::text;
select test.login(:RIVAL);
select test.blocked($$select contractor_record((select test.v('PRAIRIE')))$$, 'Not allowed', 'another contractor cannot see it');

-- owner turns off tech alerts
select test.login(test.v('PETE'));
select from set_tech_call_alerts(false);
select test.login(:MARIA);
select test.put('t6', (open_po_call(:S121, (select id from issue_types where code='drain_backup'), 'Floor drain smell')).id);
reset role;
select test.ok((select count(*) = 0 from notifications where work_order_id = test.v('t6') and user_id = test.v('TONY')), 'owner can turn off new-call alerts for techs');
update contractors set tech_call_alerts = true where id = test.v('PRAIRIE');

reset role;
\echo '=== 39. App lists keep working (one link from a visit to its technician)'
select test.ok((select count(*) = 1 from pg_constraint where conrelid = 'visits'::regclass and confrelid = 'profiles'::regclass and contype = 'f'),
  'visits have exactly one link to people, so "visit with technician name" lists work');
reset role;
\echo '=== 18. Audit'
select test.ok((select count(*) > 50 from audit_log), 'every change is in the audit trail');
\echo 'ALL TESTS PASSED'


\echo '=== 40. The store backup code cannot be read or changed by app users'
set role authenticated;
select test.login(:PAT);
select test.blocked($$select backup_code_hash from sites limit 1$$, 'permission denied', 'contractor office cannot read the store backup code');
select test.blocked($$update sites set backup_code_hash = 'x' where id = '30000000-0000-0000-0000-000000000001'$$, 'permission denied', 'contractor office cannot change the store backup code');
select test.ok((select count(*) >= 1 from sites), 'sites still readable for the rest of the app');
reset role;

\echo '=== 41. Store admin sets the map point from where they stand'
set role authenticated;
select test.login(:DOUG);
select test.ok((select (set_site_location(:S121, 47.8936, -97.0632)->>'ok')::boolean), 'store admin sets the location');
select test.login(:SAM);
select test.blocked($$select set_site_location('30000000-0000-0000-0000-000000000002', 47.0, -97.0)$$, 'permission', 'a store manager who is not admin cannot');
select test.login(:PAT);
select test.blocked($$select set_site_location('30000000-0000-0000-0000-000000000002', 47.0, -97.0)$$, 'permission', 'the contractor cannot move the store');
reset role;

\echo '=== 42. Forgot password: one-time reset link'
reset role;
select request_password_reset((select value from app_secrets where name = 'outbox'), 'Store@Northside.demo')->>'token' as rtok \gset
select test.ok(length(:'rtok') = 64, 'a reset is issued for a real login (email case does not matter)');
select test.ok((select (request_password_reset((select value from app_secrets where name = 'outbox'), 'nobody@nowhere.test')->>'ok')::boolean = false), 'unknown email: nothing issued');
select test.blocked($$select request_password_reset('wrong-key', 'store@northside.demo')$$, 'Not allowed', 'only the website (with its key) can issue resets');
set role anon;
select test.blocked($$select reset_password_with_token('abc', 'longenough123')$$, 'not valid', 'a made-up link does nothing');
select test.blocked(format('select reset_password_with_token(%L, %L)', :'rtok', 'short'), 'at least 10', 'password must be long enough');
select test.ok((select reset_password_with_token(:'rtok', 'NewPassword2026')->>'email' = 'store@northside.demo'), 'the link sets the new password');
select test.blocked(format('select reset_password_with_token(%L, %L)', :'rtok', 'AnotherOne2026'), 'not valid', 'the link works only once');
reset role;
select test.ok((select count(*) from password_resets where user_id = '00000000-0000-0000-0000-0000000000c1' and created_at > now() - interval '1 hour') = 1, 'reset logged');

\echo '=== 43. New store customer from a start link; adds locations; invites a contractor for one location'
reset role;
select create_start_link('M&L Market test') as stok \gset
set role anon;
select test.blocked(format('select start_customer(%L, %L, %L, %L, %L, %L, %L, %L, %L, null, null, null)', :'stok', 'M&L Market', 'Lee Owner', 'not-an-email', '', 'longpassword1', 'Store 1', '100 Main St, Fargo, ND', '58102'), 'valid email', 'bad email is caught');
select test.ok((select start_customer(:'stok', 'M&L Market', 'Lee Owner', 'lee@mlmarket.test', '701-555-0300', 'longpassword1',
  'M&L Fargo', '100 Main St, Fargo, ND', '58102', 46.8772, -96.7898, 'America/Chicago')->>'email' = 'lee@mlmarket.test'), 'owner sets up the company and first location');
select test.blocked(format('select start_customer(%L, %L, %L, %L, %L, %L, %L, %L, %L, null, null, null)', :'stok', 'X', 'Y', 'y@x.test', '', 'longpassword1', 'S', '1 A St', ''), 'already used', 'a start link works once');
reset role;
select id as lee from profiles where email = 'lee@mlmarket.test' \gset
select test.ok((select is_org_admin and can_approve and approval_limit is null from profiles where id = :'lee'), 'owner is admin with no approval limit');
set role authenticated;
select test.login(:'lee');
select test.ok((select (add_location('M&L Seattle', '200 Pike St, Seattle, WA', '98101', 47.61, -122.34, 'America/Los_Angeles')->>'locations')::int = 2), 'owner adds a second location (Pacific time)');
select test.blocked($$select add_location('M&L Seattle', '1 B St, Seattle, WA', '', null, null, null)$$, 'already have', 'no duplicate location names');
select test.ok((select count(*) = 2 from sites), 'owner sees exactly their two locations');
select test.ok((select timezone = 'America/Los_Angeles' from sites where name = 'M&L Seattle'), 'Seattle runs on Pacific time');
select test.ok((select (invite_contractor('Puget Refrigeration', 'Sam Puget', 'sam@puget.test', null, '{}', array[(select id from sites where name = 'M&L Seattle')])->>'token') is not null), 'invite a contractor for just the Seattle store');
select test.login(:MARIA);
select test.blocked($$select add_location('Sneaky', '1 C St, Fargo, ND', '', null, null, null)$$, 'permission', 'a non-admin cannot add locations');
reset role;

\echo '=== 44. Store admin: company profile, locations, backup-code status, equipment, team logins'
set role authenticated;
select test.login(:'lee');
select test.ok((select (update_company('M&L Market Inc', '701-555-0301', 'office@mlmarket.test')->>'ok')::boolean), 'owner edits the company profile');
select test.ok((select (update_location((select id from sites where name = 'M&L Fargo'), 'M&L Fargo Main', null, null, null, null, null)->>'ok')::boolean), 'owner renames a location');
select set_backup_code((select id from sites where name = 'M&L Fargo Main'), '4455');
select test.ok((select backup_code_set_at is not null and backup_code_set_by_name = 'Lee Owner' from sites where name = 'M&L Fargo Main'), 'backup code shows who set it and when');
select test.ok((select (save_equipment(null, (select id from sites where name = 'M&L Fargo Main'), (select code from equipment_types where contractor_id is null limit 1),
  'Hussmann', 'RL-12', 'SN-001', 'Back wall, dairy', '2024-05-01')->>'ok')::boolean), 'store adds its own equipment');
select test.blocked($$select save_equipment(null, (select id from sites where name = 'M&L Fargo Main'), null, 'Hussmann', 'RL-12', 'SN-001', 'dup', null)$$, 'already has equipment', 'no duplicate serial at a location');
select test.ok((select (add_equipment_warranty((select id from equipment where serial = 'SN-001'), 'manufacturer', '2024-05-01', '2029-05-01', 'Compressor 5 years')->>'ok')::boolean), 'store records the manufacturer warranty');
select test.ok((select (seat_info()->>'included')::int = 2 and (seat_info()->>'used')::int = 1), 'two locations = two logins, one used');
select invite_store_user('Jo Manager', 'jo@mlmarket.test', null, 'Store manager', false, true, 500, false, array[(select id from sites where name = 'M&L Seattle')])->>'token' as jotok \gset
select test.blocked($$select invite_store_user('Third Person', 'three@mlmarket.test', null, null, false, false, null, true, null)$$, 'logins are in use', 'cannot go past the included logins');
reset role; set role anon;
select test.ok((select (join_redeem(:'jotok')->>'email') = 'jo@mlmarket.test'), 'the new store manager signs in from the link');
reset role;
select id as jo from profiles where email = 'jo@mlmarket.test' \gset
set role authenticated;
select test.login(:'jo');
select test.ok((select count(*) = 1 from sites), 'the manager sees only the Seattle store');
select test.blocked($$select add_location('Mine', '1 Z St, Seattle, WA', '', null, null, null)$$, 'permission', 'the manager cannot add locations');
select test.login(:'lee');
select test.ok((select (update_store_user(:'jo', 'Store manager', false, true, 750, false, array[(select id from sites where name = 'M&L Seattle'), (select id from sites where name = 'M&L Fargo Main')], true)->>'ok')::boolean), 'owner gives the manager a second store');
select test.login(:'jo');
select test.ok((select count(*) = 2 from sites), 'now the manager sees both');
select test.login(:'lee');
select test.blocked(format('select update_store_user(%L, null, false, true, null, true, null, false)', :'lee'), 'own admin', 'owner cannot lock themselves out');
reset role;


\echo '=== 45. Per-person permissions and equipment history'
set role authenticated;
select test.login(:'lee');
select update_store_user(:'jo', 'Store manager', false, true, 750, false, array[(select id from sites where name = 'M&L Seattle')], false);
select invite_team_member('Pat Facilities', 'pat@mlmarket.test', null, 'Facilities', '{"calls":true,"equipment":true,"approve":true,"limit":"300"}', true, null)->>'token' as pattok \gset
reset role; set role anon;
select from join_redeem(:'pattok');
reset role;
select id as pat from profiles where email = 'pat@mlmarket.test' \gset
select test.ok((select can_manage_equipment and not can_manage_contractors and not is_org_admin and approval_limit = 300 from profiles where id = :'pat'), 'the link carries the permissions the admin ticked');
set role authenticated;
select test.login(:'pat');
select test.ok((select (save_equipment(null, (select id from sites where name = 'M&L Seattle'), null, 'True', 'T-49', 'TS-77', 'Deli', null)->>'ok')::boolean), 'facilities person (equipment permission) adds a unit');
select test.ok((select (save_equipment((select id from equipment where serial = 'TS-77'), (select id from sites where name = 'M&L Seattle'), null, 'True', 'T-49F', 'TS-77', 'Deli', null)->>'ok')::boolean), 'and changes it');
select test.blocked($$select invite_contractor('Nope Co', 'No One', 'no@nope.test', null, '{}', null)$$, 'permission', 'but cannot invite contractors');
select test.blocked($$select invite_team_member('X Y', 'xy@mlmarket.test', null, null, '{}', true, null)$$, 'permission', 'or add people');
select test.ok((select string_agg(action || ':' || by_name, ',' order by at) = 'added:Pat Facilities,changed:Pat Facilities' from equipment_log where equipment_id = (select id from equipment where serial = 'TS-77')), 'history shows who added and who changed it');
select test.ok((select detail like 'model T-49 → T-49F%' from equipment_log where equipment_id = (select id from equipment where serial = 'TS-77') and action = 'changed'), 'history says what changed');
select test.blocked($$select retire_equipment((select id from equipment where serial = 'TS-77'), '', false)$$, 'why', 'removing a unit needs a reason');
select test.ok((select (retire_equipment((select id from equipment where serial = 'TS-77'), 'Replaced with new unit', false)->>'ok')::boolean), 'a unit is removed with a reason (kept in history)');
select test.login(:'lee');
select test.ok((select (update_team_member(:'pat', 'Facilities', '{"calls":true,"equipment":true,"contractors":true,"team":true}', true, null, true)->>'ok')::boolean), 'admin adds the contractors and team permissions');
select test.login(:'pat');
select test.ok((select (invite_contractor('Yes Co', 'Some One', 'yes@yesco.test', null, '{}', null)->>'token') is not null), 'now they can invite contractors');
select test.blocked(format('select update_team_member(%L, null, %L, true, null, true)', :'pat', '{"admin":true}'), 'Only an admin', 'nobody but an admin makes admins');
reset role;

\echo '=== 46. Unexpected visitor: plate and photo can be required per location'
set role authenticated;
select test.login(:'lee');
select test.ok((select (store_visitor_log((select id from sites where name = 'M&L Fargo Main'), 'Walk In', null, 'Some Co', null, null, null)->>'ok')::boolean), 'by default name and company are enough');
select from set_visitor_rules((select id from sites where name = 'M&L Fargo Main'), true, false);
select test.blocked($$select store_visitor_log((select id from sites where name = 'M&L Fargo Main'), 'Walk In', null, 'Some Co', null, null, null)$$, 'plate', 'when required, the plate must be entered');
select test.ok((select (store_visitor_log((select id from sites where name = 'M&L Fargo Main'), 'Walk In', null, 'Some Co', null, 'abc 123', null)->>'ok')::boolean), 'with the plate it records');
select test.ok((select vehicle_plate = 'ABC 123' from site_visitors where visitor_name = 'Walk In' order by recorded_at desc limit 1), 'plate saved in capitals');
select test.blocked($$select store_visitor_log((select id from sites where name = 'M&L Fargo Main'), 'Walk In', null, 'X', null, 'Z1', '00000000-0000-0000-0000-000000000000/x.jpg')$$, 'Photo not valid', 'a photo must be in the store''s own folder');
reset role;
