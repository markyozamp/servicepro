-- The demo rewinds every 10 minutes: every demo call, visit, bill, flag, PM, rate, visitor and notice goes back to
-- the frozen starting point (with all times slid forward so "2 hours ago" stays 2 hours ago), and anything a visitor
-- created is removed. Demo screens show a countdown, then refresh themselves.
-- demo_freeze() captures the starting point (run by us when the demo looks right); demo_rewind() puts it back.

create table if not exists demo_frozen (
  tbl        text primary key,
  rows       jsonb not null,
  frozen_at  timestamptz not null default now()
);
alter table demo_frozen enable row level security;

-- Which rows of each table belong to the demo. $1 demo customers, $2 demo contractors, $3 demo sites, $4 demo calls,
-- $5 demo visits, $6 demo people, $7 demo equipment, $8 demo PO lines, $9 demo PM plans, $10 demo agreements.
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
    ('agreements',          'customer_id = any($1)', 2),
    ('trade_contractors',   'customer_id = any($1)', 1)
$$;

create or replace function _demo_ids(out dc uuid[], out dk uuid[], out ds uuid[], out dw uuid[], out dv uuid[], out dp uuid[],
  out de uuid[], out dl uuid[], out dpm uuid[], out da uuid[])
language plpgsql stable security definer set search_path = public as $$
begin
  select coalesce(array_agg(id), '{}') into dc from customers where name like '%(demo)';
  select coalesce(array_agg(id), '{}') into dk from contractors where name like '%(demo)';
  select coalesce(array_agg(id), '{}') into ds from sites where customer_id = any(dc);
  select coalesce(array_agg(id), '{}') into dw from work_orders where customer_id = any(dc);
  select coalesce(array_agg(id), '{}') into dv from visits where work_order_id = any(dw);
  select coalesce(array_agg(id), '{}') into dp from profiles where customer_id = any(dc) or contractor_id = any(dk);
  select coalesce(array_agg(id), '{}') into de from equipment where site_id = any(ds);
  select coalesce(array_agg(id), '{}') into dl from po_lines where work_order_id = any(dw);
  select coalesce(array_agg(id), '{}') into dpm from pm_plans where customer_id = any(dc);
  select coalesce(array_agg(id), '{}') into da from agreements where customer_id = any(dc);
end $$;
revoke execute on function _demo_ids() from public, anon, authenticated;

create or replace function demo_freeze() returns jsonb
language plpgsql security definer set search_path = public as $$
declare i record; t record; r jsonb; n int := 0;
begin
  select * into i from _demo_ids();
  if cardinality(i.dc) = 0 then raise exception 'No demo companies.'; end if;
  for t in select * from _demo_scope() loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from %I x where %s', t.tbl, t.cond)
      into r using i.dc, i.dk, i.ds, i.dw, i.dv, i.dp, i.de, i.dl, i.dpm, i.da;
    insert into demo_frozen (tbl, rows, frozen_at) values (t.tbl, r, now())
      on conflict (tbl) do update set rows = excluded.rows, frozen_at = excluded.frozen_at;
    n := n + jsonb_array_length(r);
  end loop;
  return jsonb_build_object('ok', true, 'rows', n);
end $$;
revoke execute on function demo_freeze() from public, anon, authenticated;

create or replace function demo_rewind() returns jsonb
language plpgsql security definer set search_path = public as $$
declare i record; t record; f demo_frozen; cols text; sets text; delta interval; n int; ins int := 0; del int := 0;
begin
  if not exists (select 1 from demo_frozen) then return jsonb_build_object('ok', false, 'note', 'not frozen yet'); end if;
  perform set_config('session_replication_role', 'replica', true);   -- no triggers while the demo is put back
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
  perform set_config('session_replication_role', 'origin', true);
  return jsonb_build_object('ok', true, 'removed', del, 'restored', ins);
end $$;
revoke execute on function demo_rewind() from public, anon, authenticated;

-- For the countdown: the server's clock, the next rewind, and whether the rewind is switched on
create or replace function demo_clock() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare on_ boolean := false;
begin
  if to_regclass('cron.job') is not null then
    execute 'select exists (select 1 from cron.job where jobname = ''servicepro-demo-rewind'' and active)' into on_;
  end if;
  return jsonb_build_object('now', now(), 'next', date_trunc('hour', now()) + make_interval(mins => (floor(extract(minute from now()) / 10)::int + 1) * 10),
    'every_min', 10, 'active', on_);
end $$;
grant execute on function demo_clock() to anon, authenticated;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-demo-rewind', '*/10 * * * *', 'select public.demo_rewind()');
  end if;
end $$;
