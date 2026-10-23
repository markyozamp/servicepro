-- Demo rewind: columns added after the demo was saved get their default instead of failing (approved by Mark 2026-10-23).
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
                           when column_default is not null and is_nullable = 'NO' and is_identity = 'NO' then format('coalesce(%I, %s)', column_name, column_default)
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
