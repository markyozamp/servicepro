-- The permanent demo: anyone can sign in to the demo companies, so
--  (1) demo accounts can't make changes that would break the demo for the next visitor
--      (people, admin, logos, company details, contractors, locations, equipment, routing, passwords), and
--  (2) every night the demo is put back exactly as it should be (from a saved baseline) and its dates slide to today.

create or replace function _demo_actor() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(current_setting('app.demo_guard_off', true), '') <> 'on'   -- the test suite turns the guard off
     and exists (select 1 from profiles where id = auth.uid() and email like '%.demo')
$$;

create or replace function _demo_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if _demo_actor() then
    raise exception 'This is the demo, so that change is turned off. It works in your own account.';
  end if;
  return coalesce(new, old);
end $$;

create or replace trigger demo_guard before update of is_org_admin, active, email, customer_id, contractor_id on profiles
  for each row execute function _demo_guard();
create or replace trigger demo_guard before update of name, logo_data, owner_id, email, phone on customers
  for each row execute function _demo_guard();
create or replace trigger demo_guard before update of name, logo_data, phone, email on contractors
  for each row execute function _demo_guard();
create or replace trigger demo_guard before update of store_removed_at, contractor_removed_at on customer_contractors
  for each row execute function _demo_guard();
create or replace trigger demo_guard before insert or update of name, address, lat, lon, timezone, backup_code_hash on sites
  for each row execute function _demo_guard();
create or replace trigger demo_guard before update of retired_at on equipment
  for each row execute function _demo_guard();
create or replace trigger demo_guard before update of contractor_id on trade_contractors
  for each row execute function _demo_guard();

-- Demo passwords and emails can't be changed through sign-in settings (the nightly reset sets them back regardless).
create or replace function _demo_auth_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.email like '%.demo' and session_user = 'supabase_auth_admin'
     and (new.encrypted_password is distinct from old.encrypted_password or new.email is distinct from old.email) then
    raise exception 'Demo accounts can''t change their password or email.';
  end if;
  return new;
end $$;
do $$ begin
  execute 'create or replace trigger demo_auth_guard before update on auth.users for each row execute function public._demo_auth_guard()';
exception when others then raise notice 'auth.users trigger not created: %', sqlerrm;
end $$;

-- Saved "how the demo should look" (people, companies, contractors, locations, routing, equipment, which calls belong).
create table if not exists demo_baseline (
  tbl  text not null,
  id   text not null,
  data jsonb not null,
  ver  bigint not null default 0,
  primary key (tbl, id)
);
alter table demo_baseline enable row level security;
revoke all on demo_baseline from anon, authenticated;

create or replace function demo_snapshot() returns jsonb
language plpgsql security definer set search_path = public as $$
declare dc uuid[]; dk uuid[]; n int; v bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  select array_agg(id) into dc from customers where name like '%(demo)';
  select array_agg(id) into dk from contractors where name like '%(demo)';
  -- each snapshot gets a new version; only the newest version counts (older rows are simply ignored)
  insert into demo_baseline select 'profiles', id::text, to_jsonb(p), v from profiles p where email like '%.demo' on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  insert into demo_baseline select 'customers', id::text, to_jsonb(c), v from customers c where id = any(dc) on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  insert into demo_baseline select 'contractors', id::text, to_jsonb(k), v from contractors k where id = any(dk) on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  insert into demo_baseline select 'customer_contractors', customer_id || '/' || contractor_id, to_jsonb(cc), v from customer_contractors cc where customer_id = any(dc) on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  insert into demo_baseline select 'sites', id::text, to_jsonb(s), v from sites s where customer_id = any(dc) on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  insert into demo_baseline select 'trade_contractors', id::text, to_jsonb(t), v from trade_contractors t where customer_id = any(dc) on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  insert into demo_baseline select 'equipment', id::text, to_jsonb(e), v from equipment e where customer_id = any(dc) on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  insert into demo_baseline select 'work_orders', id::text, jsonb_build_object('id', id), v from work_orders where customer_id = any(dc)
    on conflict (tbl, id) do update set data = excluded.data, ver = excluded.ver;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'calls', n, 'rows', (select count(*) from demo_baseline where ver = v));
end $$;

-- Put the demo back the way the baseline says, then slide its dates to today.
create or replace function demo_restore() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; n int := 0;
begin
  if not exists (select 1 from demo_baseline) then return jsonb_build_object('ok', false, 'note', 'no baseline'); end if;
  perform _allow_internal(true);
  update profiles t set is_org_admin = b.is_org_admin, active = b.active, all_sites = b.all_sites, site_ids = b.site_ids, title = b.title,
         can_open_calls = b.can_open_calls, can_approve = b.can_approve, approval_limit = b.approval_limit, can_manage_pm = b.can_manage_pm,
         can_manage_equipment = b.can_manage_equipment, can_manage_contractors = b.can_manage_contractors, can_manage_locations = b.can_manage_locations,
         can_manage_team = b.can_manage_team, can_manage_company = b.can_manage_company, can_see_billing = b.can_see_billing,
         full_name = b.full_name, phone = b.phone
    from demo_baseline d, jsonb_populate_record(null::profiles, d.data) b where d.ver = (select max(ver) from demo_baseline) and d.tbl = 'profiles' and t.id = b.id;
  update customers t set name = b.name, logo_data = b.logo_data, owner_id = b.owner_id, phone = b.phone, email = b.email
    from demo_baseline d, jsonb_populate_record(null::customers, d.data) b where d.ver = (select max(ver) from demo_baseline) and d.tbl = 'customers' and t.id = b.id;
  update contractors t set name = b.name, logo_data = b.logo_data, phone = b.phone, email = b.email
    from demo_baseline d, jsonb_populate_record(null::contractors, d.data) b where d.ver = (select max(ver) from demo_baseline) and d.tbl = 'contractors' and t.id = b.id;
  update customer_contractors t set store_removed_at = null, store_removed_by = null, contractor_removed_at = null, contractor_removed_by = null,
         mode = b.mode, pays_travel = b.pays_travel, unverified_time = b.unverified_time, is_primary = b.is_primary,
         accept_emergency_min = b.accept_emergency_min, accept_normal_min = b.accept_normal_min
    from demo_baseline d, jsonb_populate_record(null::customer_contractors, d.data) b
   where d.ver = (select max(ver) from demo_baseline) and d.tbl = 'customer_contractors' and t.customer_id = b.customer_id and t.contractor_id = b.contractor_id;
  update sites t set name = b.name, address = b.address, lat = b.lat, lon = b.lon, timezone = b.timezone, backup_code_hash = b.backup_code_hash,
         emergency_limit = b.emergency_limit, visitor_require_plate = b.visitor_require_plate, visitor_require_photo = b.visitor_require_photo
    from demo_baseline d, jsonb_populate_record(null::sites, d.data) b where d.ver = (select max(ver) from demo_baseline) and d.tbl = 'sites' and t.id = b.id;
  update trade_contractors t set contractor_id = b.contractor_id
    from demo_baseline d, jsonb_populate_record(null::trade_contractors, d.data) b where d.ver = (select max(ver) from demo_baseline) and d.tbl = 'trade_contractors' and t.id = b.id;
  update equipment t set retired_at = b.retired_at, retired_by = b.retired_by, retired_reason = b.retired_reason
    from demo_baseline d, jsonb_populate_record(null::equipment, d.data) b where d.ver = (select max(ver) from demo_baseline) and d.tbl = 'equipment' and t.id = b.id;
  perform _end_internal();
  -- Demo passwords back to the published one
  if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
    execute $q$update auth.users set encrypted_password = extensions.crypt('DemoService2026!', extensions.gen_salt('bf'))
      where email like '%.demo' and encrypted_password is distinct from extensions.crypt('DemoService2026!', encrypted_password)$q$;
    get diagnostics n = row_count;
  end if;
  r := refresh_demo_dates();
  -- An unexpected visitor at Store #114 today (keeps the red pin's "visitor" reason in the demo)
  if not exists (select 1 from site_visitors where site_id = '30000000-0000-0000-0000-000000000001' and recorded_at > now() - interval '12 hours') then
    insert into site_visitors (site_id, customer_id, visitor_name, company, note, vehicle_plate, recorded_by, recorded_at)
    values ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'Jake Moreno', 'Valley Ice Machines',
            'Says he''s here to check the ice machine. No call scheduled.', 'ND 4KX219',
            (select id from profiles where email = 'store@northside.demo'), now() - interval '25 minutes');
  end if;
  return jsonb_build_object('ok', true, 'passwords_reset', n, 'dates', r);
end $$;

revoke execute on function _demo_actor(), _demo_guard(), _demo_auth_guard(), demo_snapshot(), demo_restore() from public, anon, authenticated;

-- Nightly at about 3:10 am Central (08:10 UTC)
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('servicepro-demo-reset', '10 8 * * *', 'select public.demo_restore()');
  end if;
end $$;

-- Date refresh anchors on the baseline calls only, so calls or visitors added by demo visitors don't stop the slide.
create or replace function refresh_demo_dates() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  dc uuid[]; dsites uuid[]; dwo uuid[]; dvis uuid[]; dpeople uuid[]; base uuid[];
  anchor timestamptz; delta interval; t record; sets text; n int; total int := 0;
begin
  select array_agg(id) into dc from customers where name like '%(demo)';
  select array_agg(id) into dsites from sites where customer_id = any(dc);
  select array_agg(id) into dwo from work_orders where customer_id = any(dc);
  select array_agg(id) into dvis from visits where work_order_id = any(dwo);
  select array_agg(p.id) into dpeople from profiles p join contractors k on k.id = p.contractor_id where k.name like '%(demo)';
  select array_agg(id::uuid) into base from demo_baseline where tbl = 'work_orders' and ver = (select max(ver) from demo_baseline);
  if base is null then
    select greatest((select max(recorded_at) from site_visitors where site_id = any(dsites)),
                    (select max(created_at) from work_orders where id = any(dwo))) into anchor;
  else
    select max(created_at) into anchor from work_orders where id = any(base);
  end if;
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
  if not exists (select 1 from work_orders where id = any(dwo) and status = 'completed' and invoice_due_at < now()) then
    update work_orders set invoice_due_at = now() - interval '1 day'
     where id = (select id from work_orders where id = any(dwo) and status = 'completed' order by completed_at limit 1);
  end if;
  perform _end_internal();
  return jsonb_build_object('ok', true, 'shifted', delta::text, 'rows', total);
end $$;
revoke execute on function refresh_demo_dates() from public, anon, authenticated;
