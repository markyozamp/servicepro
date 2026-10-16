-- Demo service calls in every state, driven through the real rules (run once, after seed.sql, as the database owner).
do $$
declare
  SAM   uuid := '00000000-0000-0000-0000-0000000000c1';
  MARIA uuid := '00000000-0000-0000-0000-0000000000c2';
  PAT   uuid := '00000000-0000-0000-0000-0000000000a2';
  MIKE  uuid := '00000000-0000-0000-0000-0000000000a3';
  LUIS  uuid := '00000000-0000-0000-0000-0000000000a4';
  KAREN uuid := '00000000-0000-0000-0000-0000000000d1';
  S114  uuid := '30000000-0000-0000-0000-000000000001';
  S121  uuid := '30000000-0000-0000-0000-000000000002';
  SJ    uuid := '30000000-0000-0000-0000-000000000003';
  FREEZER uuid := '80000000-0000-0000-0000-000000000001';
  COND  uuid := '80000000-0000-0000-0000-000000000002';
  w work_orders; v visits; l po_lines; c text; r jsonb;
begin
  -- helpers inline: login = set the JWT subject for this transaction
  ---------------------------------------------------------------- D. Completed 2 days ago, bill pending
  perform set_config('request.jwt.claim.sub', SAM::text, true);
  w := create_work_order(S114, (select id from issue_types where code = 'rack_alarm'), 'Rack alarm — condenser 3 fan not running, head pressure high', COND);
  perform set_config('request.jwt.claim.sub', PAT::text, true);
  v := assign_work_order(w.id, MIKE);
  perform _allow_internal(true);
  update visits set assigned_at = now() - interval '2900 minutes' where id = v.id;
  update work_orders set created_at = now() - interval '2905 minutes',
    response_due_at = response_due_at - (created_at - (now() - interval '2905 minutes')) where id = w.id;
  perform _end_internal();
  perform set_config('request.jwt.claim.sub', MIKE::text, true);
  perform tech_received(v.id, now() - interval '2895 minutes');
  perform tech_start(v.id, now() - interval '2890 minutes', 47.95, -97.10);
  perform tech_arrive(v.id, now() - interval '2860 minutes', 47.9101, -97.0491);
  select code into c from visit_codes where visit_id = v.id;
  perform tech_checkin(v.id, 'code', c, p_at => now() - interval '2859 minutes');
  insert into photos (work_order_id, visit_id, kind, storage_path, taken_at, uploaded_by)
  select w.id, v.id, k::photo_kind, 'demo/' || k || '.jpg', now() - interval '2855 minutes', MIKE from unnest(array['nameplate','before']) k;
  perform confirm_equipment(v.id, 'condenser', 'Heatcraft', 'MOH050H2C', 'T21K04512', 'Roof, condenser 3', COND);
  perform set_repair_type(v.id, '50000000-0000-0000-0000-000000000001');
  l := request_po_line(w.id, 'repair', 120, 'Condenser fan motor seized; replace motor and run capacitor');
  perform set_config('request.jwt.claim.sub', MARIA::text, true);
  perform decide_po_line(l.id, true);
  perform set_config('request.jwt.claim.sub', MIKE::text, true);
  insert into photos (work_order_id, visit_id, kind, storage_path, taken_at, uploaded_by)
  values (w.id, v.id, 'after', 'demo/after.jpg', now() - interval '2790 minutes', MIKE);
  r := tech_finish_visit(v.id, 'completed', p_at => now() - interval '2785 minutes');
  if not (r->>'ok')::boolean then raise exception 'D not completed: %', r; end if;
  perform tech_depart(v.id, now() - interval '2783 minutes');

  ---------------------------------------------------------------- C. Waiting for parts (Store #121)
  perform set_config('request.jwt.claim.sub', MARIA::text, true);
  w := create_work_order(S121, (select id from issue_types where code = 'self_contained_down'), 'Beverage cooler by front registers not cooling');
  perform set_config('request.jwt.claim.sub', PAT::text, true);
  v := assign_work_order(w.id, MIKE);
  perform _allow_internal(true);
  update visits set assigned_at = now() - interval '320 minutes' where id = v.id;
  update work_orders set created_at = now() - interval '325 minutes' where id = w.id;
  perform _end_internal();
  perform set_config('request.jwt.claim.sub', MIKE::text, true);
  perform tech_start(v.id, now() - interval '300 minutes', 47.95, -97.10);
  perform tech_arrive(v.id, now() - interval '280 minutes', 47.8936, -97.0632);
  insert into photos (work_order_id, visit_id, kind, storage_path, taken_at, uploaded_by)
  select w.id, v.id, k::photo_kind, 'demo/' || k || '.jpg', now() - interval '275 minutes', MIKE from unnest(array['nameplate','before']) k;
  perform confirm_equipment(v.id, 'self_contained', 'True', 'GDM-49', 'T49-77812', 'Front end by registers');
  r := tech_finish_visit(v.id, 'parts_needed', 'Condenser fan motor failed; not on truck',
    jsonb_build_array(jsonb_build_object('part_id', '40000000-0000-0000-0000-000000000001', 'quantity', 1,
      'supplier', 'Johnstone Supply', 'expected_on', current_date + 2)),
    now() - interval '250 minutes');
  if not (r->>'ok')::boolean then raise exception 'C not parked: %', r; end if;
  perform tech_depart(v.id, now() - interval '248 minutes');

  ---------------------------------------------------------------- B. On site, PO1xxxA waiting for approval (emergency)
  perform set_config('request.jwt.claim.sub', SAM::text, true);
  w := create_work_order(S114, (select id from issue_types where code = 'wi_freezer_down'), 'Walk-in freezer at 28°F and rising, ice on evaporator', FREEZER);
  perform set_config('request.jwt.claim.sub', PAT::text, true);
  v := assign_work_order(w.id, LUIS);
  perform _allow_internal(true);
  update visits set assigned_at = now() - interval '100 minutes' where id = v.id;
  update work_orders set created_at = now() - interval '105 minutes',
    response_due_at = response_due_at - (created_at - (now() - interval '105 minutes')) where id = w.id;
  perform _end_internal();
  perform set_config('request.jwt.claim.sub', LUIS::text, true);
  perform tech_start(v.id, now() - interval '95 minutes', 47.95, -97.10);
  perform tech_arrive(v.id, now() - interval '70 minutes', 47.9100, -97.0490);
  select code into c from visit_codes where visit_id = v.id;
  perform tech_checkin(v.id, 'code', c, p_at => now() - interval '69 minutes');
  insert into photos (work_order_id, visit_id, kind, storage_path, taken_at, uploaded_by)
  select w.id, v.id, k::photo_kind, 'demo/' || k || '.jpg', now() - interval '65 minutes', LUIS from unnest(array['nameplate','before']) k;
  perform confirm_equipment(v.id, 'walk_in_freezer', 'Bohn', 'BHA0400', 'K19C23311', 'Back room, walk-in freezer', FREEZER);
  perform request_po_line(w.id, 'repair', 480, 'Defrost heater burned open; evaporator iced solid. Replace heater, clear ice, run defrost.',
    '{"parts":[{"name":"Defrost heater 240V","qty":1,"price":139}],"labor_hours":2.5}');

  ---------------------------------------------------------------- A. En route with ETA
  perform set_config('request.jwt.claim.sub', SAM::text, true);
  w := create_work_order(S114, (select id from issue_types where code = 'case_warm'), 'Dairy case 4 reading 46°F');
  perform set_config('request.jwt.claim.sub', PAT::text, true);
  v := assign_work_order(w.id, MIKE);
  perform set_config('request.jwt.claim.sub', MIKE::text, true);
  perform tech_received(v.id);
  perform tech_start(v.id, now(), 47.95, -97.10);
  perform tech_update_eta(v.id, now() + interval '18 minutes');

  ---------------------------------------------------------------- E. New residential call, not yet assigned
  perform set_config('request.jwt.claim.sub', KAREN::text, true);
  w := create_work_order(SJ, (select id from issue_types where code = 'no_heat'), 'Furnace runs but blows cold air');

  ---------------------------------------------------------------- PM: open due / overdue PM work orders
  perform set_config('request.jwt.claim.sub', '', true);
  perform pm_generate();
end $$;
