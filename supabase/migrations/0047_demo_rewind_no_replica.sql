-- Demo rewind without replica mode (not allowed on hosted Postgres): the few triggers that matter for an insert or
-- delete (audit log, call rules, new-call alerts) stand aside while app.demo_rewind = 'on'. Agreements go in first.

do $$
declare f text; d text; n text;
begin
  foreach f in array array['_audit','_invoice_rules','_visit_accepts','_wo_relationship_guard','_tech_new_call'] loop
    select pg_get_functiondef(p.oid) into d from pg_proc p where p.proname = f and p.pronamespace = 'public'::regnamespace;
    if d is null or d like '%app.demo_rewind%' then continue; end if;
    n := regexp_replace(d, E'\nbegin\n', E'\nbegin\n  if current_setting(''app.demo_rewind'', true) = ''on'' then return coalesce(new, old); end if;\n');
    if n = d then raise exception 'Could not patch %', f; end if;
    execute n;
  end loop;
end $$;

create or replace function _demo_scope() returns table (tbl text, cond text, ord int)
language sql immutable as $$
  values
    ('approval_links',      'po_line_id = any($8)', 1),
    ('visit_codes',         'visit_id = any($5)', 1),
    ('gps_logs',            'work_order_id = any($4) or visit_id = any($5)', 1),
    ('time_overrides',      'work_order_id = any($4)', 1),
    ('closeout_overrides',  'work_order_id = any($4)', 1),
    ('parts_used',          'work_order_id = any($4)', 1),
    ('parts_runs',          'work_order_id = any($4)', 1),
    ('parts_orders',        'work_order_id = any($4)', 1),
    ('photos',              'work_order_id = any($4) or equipment_id = any($7)', 1),
    ('call_invoices',       'work_order_id = any($4)', 1),
    ('guardrail_flags',     'work_order_id = any($4)', 1),
    ('platform_fees',       'work_order_id = any($4)', 1),
    ('usage_events',        'customer_id = any($1)', 1),
    ('notifications',       'user_id = any($6) or work_order_id = any($4)', 1),
    ('warranties',          'equipment_id = any($7) or work_order_id = any($4)', 1),
    ('equipment_log',       'equipment_id = any($7)', 1),
    ('po_lines',            'work_order_id = any($4)', 2),
    ('visits',              'work_order_id = any($4)', 2),
    ('work_orders',         'id = any($4)', 3),
    ('pm_plan_parts',       'pm_plan_id = any($9)', 3),
    ('pm_plans',            'customer_id = any($1)', 4),
    ('equipment',           'site_id = any($3)', 5),
    ('site_visitors',       'site_id = any($3)', 1),
    ('contractor_rates',    'customer_id = any($1) or contractor_id = any($2)', 1),
    ('rate_prospects',      'customer_id = any($1)', 1),
    ('time_entries',        'profile_id = any($6)', 1),
    ('timesheet_approvals', 'profile_id = any($6)', 1),
    ('usage_topups',        'customer_id = any($1)', 1),
    ('agreement_sites',     'agreement_id = any($10) or site_id = any($3)', 1),
    ('agreements',          'customer_id = any($1)', 6),
    ('trade_contractors',   'customer_id = any($1)', 1)
$$;

create or replace function demo_rewind() returns jsonb
language plpgsql security definer set search_path = public as $$
declare i record; t record; f demo_frozen; cols text; sets text; delta interval; n int; ins int := 0; del int := 0;
begin
  if not exists (select 1 from demo_frozen) then return jsonb_build_object('ok', false, 'note', 'not frozen yet'); end if;
  perform set_config('app.demo_rewind', 'on', true);   -- audit, alerts and call rules stand aside while the demo is put back
  select * into i from _demo_ids();
  -- 1) remove everything demo, children first
  for t in select * from _demo_scope() order by ord loop
    execute format('delete from %I where %s', t.tbl, t.cond) using i.dc, i.dk, i.ds, i.dw, i.dv, i.dp, i.de, i.dl, i.dpm, i.da;
    get diagnostics n = row_count; del := del + n;
  end loop;
  -- 2) put the frozen rows back, parents first, with every time slid forward
  for t in select * from _demo_scope() order by ord desc loop
    select * into f from demo_frozen where demo_frozen.tbl = t.tbl;
    if f.tbl is null or jsonb_array_length(f.rows) = 0 then continue; end if;
    delta := now() - f.frozen_at;
    select string_agg(format('%I', column_name), ', ' order by ordinal_position),
           string_agg(case when data_type = 'timestamp with time zone' then format('%1$I + $2', column_name)
                           when data_type = 'date' then format('(%1$I + $2)::date', column_name)
                           else format('%I', column_name) end, ', ' order by ordinal_position)
      into cols, sets
      from information_schema.columns where table_schema = 'public' and table_name = t.tbl and is_generated = 'NEVER';
    execute format('insert into %I (%s) overriding system value select %s from jsonb_populate_recordset(null::%I, $1)', t.tbl, cols, sets, t.tbl)
      using f.rows, date_trunc('minute', delta);
    get diagnostics n = row_count; ins := ins + n;
  end loop;
  perform set_config('app.demo_rewind', 'off', true);
  return jsonb_build_object('ok', true, 'removed', del, 'restored', ins);
end $$;
revoke execute on function demo_rewind() from public, anon, authenticated;
