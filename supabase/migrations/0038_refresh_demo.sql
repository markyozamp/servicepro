-- Daily demo refresh: slides every demo company's dates forward so the demo looks like "today"
-- (latest activity ~10 minutes ago; overdue bills stay overdue, tomorrow's trips stay tomorrow).
-- Only the (demo) companies and their contractors' people are touched. Alerts are not re-sent.
-- Run as the database owner: select refresh_demo_dates();
create or replace function refresh_demo_dates() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  dc uuid[]; dsites uuid[]; dwo uuid[]; dvis uuid[]; dpeople uuid[];
  anchor timestamptz; delta interval; t record; cols text; sets text; n int; total int := 0;
begin
  select array_agg(id) into dc from customers where name like '%(demo)';
  select array_agg(id) into dsites from sites where customer_id = any(dc);
  select array_agg(id) into dwo from work_orders where customer_id = any(dc);
  select array_agg(id) into dvis from visits where work_order_id = any(dwo);
  select array_agg(p.id) into dpeople from profiles p join contractors k on k.id = p.contractor_id where k.name like '%(demo)';
  select greatest((select max(recorded_at) from site_visitors where site_id = any(dsites)),
                  (select max(created_at) from work_orders where id = any(dwo))) into anchor;
  delta := date_trunc('minute', now() - anchor - interval '10 minutes');
  if delta < interval '1 hour' then return jsonb_build_object('ok', true, 'shifted', '0', 'note', 'already fresh'); end if;
  perform _allow_internal(true);
  for t in select * from (values
      ('work_orders', 'id = any($1)'), ('visits', 'id = any($2)'), ('po_lines', 'work_order_id = any($1)'),
      ('photos', 'work_order_id = any($1)'), ('call_invoices', 'work_order_id = any($1)'), ('guardrail_flags', 'work_order_id = any($1)'),
      ('parts_orders', 'work_order_id = any($1)'), ('parts_runs', 'work_order_id = any($1)'), ('parts_used', 'work_order_id = any($1)'),
      ('time_overrides', 'work_order_id = any($1)'), ('closeout_overrides', 'work_order_id = any($1)'), ('gps_logs', 'work_order_id = any($1)'),
      ('visit_codes', 'visit_id = any($2)'), ('site_visitors', 'site_id = any($3)'), ('pm_plans', 'customer_id = any($4)'),
      ('agreements', 'customer_id = any($4)'), ('time_entries', 'profile_id = any($5)')) x(tbl, cond) loop
    select string_agg(format('%I = %I + $6', column_name, column_name), ', ') into sets
      from information_schema.columns where table_schema = 'public' and table_name = t.tbl
       and data_type in ('timestamp with time zone', 'date') and is_generated = 'NEVER';
    if sets is null then continue; end if;
    execute format('update %I set %s where %s', t.tbl, sets, t.cond) using dwo, dvis, dsites, dc, dpeople, delta;
    get diagnostics n = row_count; total := total + n;
  end loop;
  -- keep one late bill so the red pin and "Late bills" show
  if not exists (select 1 from work_orders where id = any(dwo) and status = 'completed' and invoice_due_at < now()) then
    update work_orders set invoice_due_at = now() - interval '1 day'
     where id = (select id from work_orders where id = any(dwo) and status = 'completed' order by completed_at limit 1);
  end if;
  perform _end_internal();
  return jsonb_build_object('ok', true, 'shifted', delta::text, 'rows', total);
end $$;
revoke execute on function refresh_demo_dates() from public, anon, authenticated;
