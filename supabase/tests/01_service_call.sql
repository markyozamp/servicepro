-- End-to-end test: one service call from creation to QuickBooks export,
-- plus every way someone might try to cheat or skip a step.
\set ON_ERROR_STOP on
\set QUIET on
\pset format unaligned
\pset tuples_only on

create schema if not exists test;
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
  if p_like is not null and sqlerrm not ilike '%' || p_like || '%' then
    raise exception 'FAIL (wrong error) %: %', label, sqlerrm; end if;
  return 'PASS  ' || label || '  → "' || sqlerrm || '"';
end $$;
grant usage on schema test to authenticated;
grant execute on all functions in schema test to authenticated;
create table test.ctx (k text primary key, v uuid);
grant all on test.ctx to authenticated;

\echo '--- Customer opens a call with a $500 PO cap'
set role authenticated;
select test.login('00000000-0000-0000-0000-0000000000c1');
insert into test.ctx select 'wo', id from create_work_order(
  '30000000-0000-0000-0000-000000000001', 'Dairy case warm, condenser fan not spinning',
  p_po_number => 'NG-4471', p_po_cap => 500);
select test.ok((select status = 'created' and po_cap = 500 from work_orders where id = (select v from test.ctx where k='wo')), 'call created with PO cap');

\echo '--- Assignment'
select test.blocked($$select assign_work_order((select v from test.ctx where k='wo'), '00000000-0000-0000-0000-0000000000a3')$$,
  'Only the contractor office', 'customer cannot assign technicians');
select test.login('00000000-0000-0000-0000-0000000000a3');
select test.blocked($$select tech_start((select v from test.ctx where k='wo'))$$, 'not assigned', 'tech cannot start an unassigned job');
select test.login('00000000-0000-0000-0000-0000000000a2');
select test.blocked($$select assign_work_order((select v from test.ctx where k='wo'), '00000000-0000-0000-0000-0000000000b3')$$,
  'not an active technician', 'cannot assign another company''s tech');
select from assign_work_order((select v from test.ctx where k='wo'), '00000000-0000-0000-0000-0000000000a3');
select test.ok((select status = 'assigned' from work_orders where id = (select v from test.ctx where k='wo')), 'dispatcher assigned Mike');
-- Test-only: pretend the dispatch happened 3 hours ago so we can replay a realistic timeline.
-- (Device times earlier than dispatch are clamped to the dispatch time.)
reset role;
begin;
select from _allow_internal();
update work_orders set assigned_at = now() - interval '3 hours' where id = (select v from test.ctx where k='wo');
select from _end_internal();
commit;
set role authenticated;

\echo '--- Technician drives and arrives'
select test.login('00000000-0000-0000-0000-0000000000a3');
select test.blocked($$update work_orders set status = 'completed'$$, 'permission denied', 'tech cannot edit status directly');
select test.blocked($$select tech_start((select v from test.ctx where k='wo'), now() + interval '1 hour')$$,
  'clock is ahead', 'future device time rejected');
select from tech_start((select v from test.ctx where k='wo'), now() - interval '2 hours', 47.95, -97.10);
select from tech_update_eta((select v from test.ctx where k='wo'), now() + interval '25 minutes');
select from tech_update_eta((select v from test.ctx where k='wo'), now() + interval '30 minutes');  -- small change, no new text
select test.ok(log_gps('[{"lat":47.92,"lon":-97.08,"at":"2020-01-01T00:00:00Z"},{"lat":47.915,"lon":-97.06,"at":"2020-01-01T00:01:00Z"}]'::jsonb) = 2, 'offline location pings uploaded in a batch');
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.ok((select eta_at is not null from work_orders where id = (select v from test.ctx where k='wo')), 'store sees the ETA');
select test.ok((select count(*) = 1 from notifications where type = 'eta_update' and message like '%expected at%'), 'store texted ETA once (5-min change not re-sent)');
select test.ok((select count(*) = 0 from gps_logs where event = 'ping'), 'store cannot see live location pings');
select test.login('00000000-0000-0000-0000-0000000000a3');
-- arrival from the parking lot, ~100 ft away, synced later from offline queue
select from tech_arrive((select v from test.ctx where k='wo'), now() - interval '100 minutes', 47.9102, -97.0491);
select test.ok((select status = 'on_site' from work_orders where id = (select v from test.ctx where k='wo')), 'arrived on site');
select from tech_arrive((select v from test.ctx where k='wo'), now(), 47.9102, -97.0491);  -- duplicate sync
select test.ok((select arrived_at < now() - interval '99 minutes' from work_orders where id = (select v from test.ctx where k='wo')),
  'duplicate arrival sync ignored (original time kept)');

\echo '--- Trying to complete with nothing documented'
select test.ok((select (r->>'ok')::boolean = false and jsonb_array_length(r->'missing') = 6
               from tech_complete((select v from test.ctx where k='wo'), now() - interval '30 minutes') r),
  'completion blocked: 6 items missing (equipment, nameplate, before, after, repair, parts)');
select '      checklist: ' || string_agg(message, ' | ') from completion_check((select v from test.ctx where k='wo'));

\echo '--- Photos, equipment, repair'
insert into photos (work_order_id, kind, storage_path, taken_at, uploaded_by)
select c.v, pk::photo_kind, 'wo/' || c.v || '/' || pk || '.jpg', now() - interval '95 minutes', auth.uid()
from test.ctx c, unnest(array['nameplate','before','after']) pk where c.k = 'wo';
select test.blocked($$update photos set storage_path = 'swapped.jpg'$$, 'permission denied', 'photos cannot be altered after upload');
select test.blocked($$select confirm_equipment((select v from test.ctx where k='wo'), 'condenser', 'Heatcraft', 'MOH050', '')$$,
  'serial are both required', 'equipment needs model AND serial');
select from confirm_equipment((select v from test.ctx where k='wo'), 'condenser', 'Heatcraft', 'MOH050H2C', 'T21K04512', 'Roof, condenser 3');
select from set_repair_type((select v from test.ctx where k='wo'), '50000000-0000-0000-0000-000000000001');
select test.ok((select count(*) = 2 from parts_used where work_order_id = (select v from test.ctx where k='wo')), 'repair kit auto-filled (motor + capacitor)');
select '      auto summary: ' || work_summary from work_orders where id = (select v from test.ctx where k='wo');
select from set_part_used((select v from test.ctx where k='wo'), '40000000-0000-0000-0000-000000000003', 1);  -- blade was cracked too

\echo '--- PO cap'
select test.ok((select count(*) = 1 and bool_and(item = 'po_cap') from completion_check((select v from test.ctx where k='wo'), now() - interval '30 minutes')),
  'only remaining blocker is the PO cap');
select '      ' || message from completion_check((select v from test.ctx where k='wo'), now() - interval '30 minutes');
select test.ok((select count(*) = 0 from guardrail_flags), 'tech cannot see review flags');
select from request_approval((select v from test.ctx where k='wo'), 100, 'Fan blade cracked, replaced with motor');
select test.ok((select status = 'awaiting_approval' from work_orders where id = (select v from test.ctx where k='wo')), 'job waiting on customer');
select test.blocked($$select decide_approval((select id from approvals limit 1), true)$$, 'Only the customer', 'tech cannot approve own request');

select test.login('00000000-0000-0000-0000-0000000000c1');
select test.ok((select count(*) >= 1 from notifications where type = 'approval_request'), 'customer got the approval request');
select from decide_approval((select id from approvals limit 1), true);

\echo '--- Completion'
select test.login('00000000-0000-0000-0000-0000000000a3');
select test.ok((select (r->>'ok')::boolean from tech_complete((select v from test.ctx where k='wo'), now() - interval '30 minutes') r),
  'job completed');
select '      ' || format('labor %s min billed = $%s | parts $%s | trip $%s | TOTAL $%s', labor_minutes_billed, total_labor, total_parts, total_trip, total_cost)
from work_orders where id = (select v from test.ctx where k='wo');
select test.ok((select total_cost = 582.25 from work_orders where id = (select v from test.ctx where k='wo')),
  'cost math: 70 min → 75 billed ($156.25) + parts $381 + trip $45 = $582.25');
select test.blocked($$select tech_start((select v from test.ctx where k='wo'))$$, null, 'cannot restart a completed job');

\echo '--- Office review'
select test.login('00000000-0000-0000-0000-0000000000a1');
select '      flag: ' || flag || ' — ' || description from guardrail_flags where resolved_at is null and blocking;
select test.ok((select not invoice_ready from work_orders where id = (select v from test.ctx where k='wo')), 'not invoice-ready while flags open');
select test.blocked($$select mark_exported((select v from test.ctx where k='wo'), 'QB-1')$$, 'Resolve all review flags', 'export blocked by open flags');
select test.blocked($$update work_orders set arrived_at = now() - interval '5 hours'$$, 'permission denied', 'office cannot hand-edit arrival time');

-- Phone clock was right but GPS lagged inside the steel building: correct arrival by 10 min
select test.blocked($$select override_time((select v from test.ctx where k='wo'), 'arrived_at', now() - interval '110 minutes', 'gps')$$,
  'check', 'override needs a real reason');
select from override_time((select v from test.ctx where k='wo'), 'arrived_at', now() - interval '110 minutes',
  'GPS lag inside building; store camera shows 10 min earlier');
select '      after override: TOTAL $' || total_cost from work_orders where id = (select v from test.ctx where k='wo');
select test.ok((select exists (select 1 from guardrail_flags where flag = 'po_exceeded' and resolved_at is null and blocking)),
  'override pushing cost past approved PO raises a blocking flag');

select from guardrail_flags g, resolve_flag(g.id, 'Reviewed with customer') where g.resolved_at is null and g.blocking;
select test.ok((select invoice_ready from work_orders where id = (select v from test.ctx where k='wo')), 'invoice-ready after review');
select '      invoice: ' || invoice_payload((select v from test.ctx where k='wo'))::text;
select from mark_exported((select v from test.ctx where k='wo'), 'QB-INV-2231');
select test.ok((select status = 'invoiced' from work_orders where id = (select v from test.ctx where k='wo')), 'exported to QuickBooks');
select test.blocked($$update work_orders set work_summary = 'changed' where id = (select v from test.ctx where k='wo')$$, 'locked', 'invoiced job is locked');
reset role;  -- platform-level check (each side can only see its own fee)
select test.ok((select count(*) = 2 and bool_and(amount = 5) from platform_fees where work_order_id = (select v from test.ctx where k='wo')),
  '$5 fee recorded for BOTH contractor and store');
set role authenticated;
select test.ok((select count(*) = 1 from platform_fees), 'contractor sees only its own fee');

\echo '--- What the customer sees'
select test.login('00000000-0000-0000-0000-0000000000c1');
select test.ok((select count(*) = 0 from guardrail_flags), 'customer never sees internal review flags');
select test.ok((select count(*) = 1 from time_overrides), 'customer DOES see the logged time correction');
select test.ok((select count(*) = 3 from photos), 'customer sees the photos');
select test.ok((select count(*) = 1 from equipment where serial = 'T21K04512'), 'equipment history built for the store');

\echo '--- Outsiders'
select test.login('00000000-0000-0000-0000-0000000000b3');
select test.ok((select count(*) = 0 from work_orders), 'other contractor''s tech sees no jobs');
select test.ok((select count(*) = 0 from equipment), '... and no equipment');

\echo '--- Second call: arrival far from the store'
select test.login('00000000-0000-0000-0000-0000000000a2');
insert into test.ctx select 'wo2', id from create_work_order('30000000-0000-0000-0000-000000000001', 'Ice machine not making ice');
select from assign_work_order((select v from test.ctx where k='wo2'), '00000000-0000-0000-0000-0000000000a3');
select test.login('00000000-0000-0000-0000-0000000000a3');
select from tech_start((select v from test.ctx where k='wo2'), now() - interval '20 minutes');
select from tech_arrive((select v from test.ctx where k='wo2'), now() - interval '5 minutes', 47.93, -97.05, 'manual');
select test.login('00000000-0000-0000-0000-0000000000a1');
select test.ok((select exists (select 1 from guardrail_flags where work_order_id = (select v from test.ctx where k='wo2') and flag = 'gps_mismatch')),
  'manual "Arrived" 1.4 miles from store gets flagged');
select '      ' || description from guardrail_flags where work_order_id = (select v from test.ctx where k='wo2');

reset role;
\echo '--- Audit trail rows written:'
select count(*) from audit_log;
\echo 'ALL TESTS PASSED'
