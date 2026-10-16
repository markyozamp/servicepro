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
  'wrong code is recorded as NOT verified (works offline; checked on sync)');
select test.login(:SAM);
select test.ok((select count(*) = 1 from guardrail_flags where flag = 'checkin_unverified' and resolved_at is null),
  'store sees the unverified check-in flag');
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

\echo '=== 14. Residential homeowner'
select test.login(:KAREN);
select test.put('wo4', (create_work_order('30000000-0000-0000-0000-000000000003', (select id from issue_types where code='no_heat'))).id);
select test.ok((select count(*) = 1 from work_orders), 'homeowner sees only her own call');
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

\echo '=== 18. Audit'
select test.ok((select count(*) > 50 from audit_log), 'every change is in the audit trail');
\echo 'ALL TESTS PASSED'
