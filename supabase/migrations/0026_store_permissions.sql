-- Per-person store permissions (admin picks: open calls, approve, equipment, contractors & QR, locations, team, admin),
-- equipment history (who added / changed / removed), and "Service Call Proof" in two old messages.

alter table profiles add column if not exists can_manage_equipment   boolean not null default false;
alter table profiles add column if not exists can_manage_contractors boolean not null default false;
alter table profiles add column if not exists can_manage_locations   boolean not null default false;
alter table profiles add column if not exists can_manage_team        boolean not null default false;

create or replace function store_can(p_customer uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select is_platform_admin() or exists (select 1 from profiles p where p.id = auth.uid() and p.active and p.customer_id = p_customer and (
    p.is_org_admin or case p_perm
      when 'equipment'   then p.can_manage_equipment or p.can_manage_pm
      when 'contractors' then p.can_manage_contractors
      when 'locations'   then p.can_manage_locations
      when 'team'        then p.can_manage_team
      when 'calls'       then p.can_open_calls
      else false end))
$$;
grant execute on function store_can(uuid, text) to authenticated;

-- invite_contractor: admin or "contractors" permission
create or replace function invite_contractor(p_company text, p_contact_name text, p_email text default null, p_phone text default null,
  p_trade_ids smallint[] default '{}', p_site_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cid uuid; tok uuid; tr smallint; st uuid;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to invite contractors.'; end if;
  if coalesce(length(trim(p_company)), 0) < 2 or coalesce(length(trim(p_contact_name)), 0) < 2 then
    raise exception 'Enter the company and the person''s name.';
  end if;
  if nullif(trim(p_email), '') is null and nullif(trim(p_phone), '') is null then raise exception 'Enter an email or a mobile number.'; end if;
  if p_site_ids is not null and exists (select 1 from unnest(p_site_ids) x where not exists (
       select 1 from sites s where s.id = x and s.customer_id = m.customer_id)) then raise exception 'Not your location.'; end if;
  insert into contractors (name, phone, email) values (trim(p_company), nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''))
  returning id into cid;
  insert into customer_contractors (contractor_id, customer_id, is_primary, mode)
  values (cid, m.customer_id, not exists (select 1 from customer_contractors where customer_id = m.customer_id), 'verify');
  foreach tr in array coalesce(p_trade_ids, '{}') loop
    if coalesce(cardinality(p_site_ids), 0) = 0 then
      perform set_trade_contractor(null, tr, cid);
    else
      foreach st in array p_site_ids loop perform set_trade_contractor(st, tr, cid); end loop;
    end if;
  end loop;
  insert into join_links (kind, contractor_id, customer_id, full_name, phone, email, created_by,
                          perms)
  values ('contractor_owner', cid, m.customer_id, trim(p_contact_name), nullif(trim(p_phone), ''), nullif(lower(trim(p_email)), ''), m.id,
          '{"is_org_admin":true,"can_dispatch":true,"can_bill":true,"is_technician":true}')
  returning token into tok;
  return jsonb_build_object('token', tok, 'contractor_id', cid);
end $$;

-- set_contractor_terms: admin or "contractors" permission
create or replace function set_contractor_terms(p_contractor uuid, p_mode text default null, p_pays_travel text default null,
  p_accept_emergency_min int default null, p_accept_normal_min int default null)
returns customer_contractors language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to change this.'; end if;
  update customer_contractors set mode = coalesce(p_mode, mode), pays_travel = coalesce(p_pays_travel, pays_travel),
         accept_emergency_min = coalesce(p_accept_emergency_min, accept_emergency_min),
         accept_normal_min = coalesce(p_accept_normal_min, accept_normal_min)
   where customer_id = m.customer_id and contractor_id = p_contractor returning * into cc;
  if cc.contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  return cc;
end $$;

-- set_trade_contractor: admin or "contractors" permission
create or replace function set_trade_contractor(p_site uuid, p_trade smallint, p_contractor uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cust uuid;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to change this.'; end if;
  cust := m.customer_id;
  if p_site is not null and not exists (select 1 from sites where id = p_site and customer_id = cust) then raise exception 'Not your location.'; end if;
  if (_cc(cust, p_contractor)).contractor_id is null and p_contractor is not null then raise exception 'That contractor does not serve you.'; end if;
  if p_site is null then
    update trade_contractors set contractor_id = p_contractor, updated_at = now() where customer_id = cust and site_id is null and trade_id = p_trade;
  else
    update trade_contractors set contractor_id = p_contractor, updated_at = now() where site_id = p_site and trade_id = p_trade;
  end if;
  if not found then
    insert into trade_contractors (customer_id, site_id, trade_id, contractor_id) values (cust, p_site, p_trade, p_contractor);
  end if;
end $$;

-- set_unverified_rule: admin or "contractors" permission
create or replace function set_unverified_rule(p_contractor uuid, p_rule text) returns customer_contractors
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); cc customer_contractors;
begin
  if m.customer_id is null or not store_can(m.customer_id, 'contractors') then raise exception 'You don''t have permission to change this.'; end if;
  if p_rule not in ('review','no_pay') then raise exception 'Choose review or no_pay.'; end if;
  update customer_contractors set unverified_time = p_rule where customer_id = m.customer_id and contractor_id = p_contractor returning * into cc;
  if cc.contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  return cc;
end $$;

-- set_report_pin: admin or "contractors" permission
create or replace function set_report_pin(p_site uuid, p_pin text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from sites s where s.id = p_site and store_can(s.customer_id, 'contractors')) then
    raise exception 'You don''t have permission to set the PIN.';
  end if;
  if trim(p_pin) !~ '^[0-9]{4,6}$' then raise exception 'The PIN must be 4 to 6 digits.'; end if;
  insert into site_report_pins (site_id, pin_hash) values (p_site, extensions.crypt(trim(p_pin), extensions.gen_salt('bf')))
  on conflict (site_id) do update set pin_hash = excluded.pin_hash, updated_at = now();
end $$;

-- set_site_settings: admin or "locations" permission
create or replace function set_site_settings(p_site uuid, p_emergency_limit numeric default null,
  p_wifi_ssid text default null, p_wifi_password text default null) returns sites
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not store_can(s.customer_id, 'locations') then raise exception 'You don''t have permission to change location settings.'; end if;
  if p_emergency_limit is not null and p_emergency_limit < 0 then raise exception 'The emergency limit cannot be negative.'; end if;
  update sites set emergency_limit = p_emergency_limit where id = p_site returning * into s;
  insert into site_wifi (site_id, ssid, password, updated_by)
  values (p_site, nullif(trim(p_wifi_ssid), ''), case when nullif(trim(p_wifi_ssid), '') is null then null else nullif(p_wifi_password, '') end, auth.uid())
  on conflict (site_id) do update set ssid = excluded.ssid, password = excluded.password, updated_by = excluded.updated_by, updated_at = now();
  return s;
end $$;

-- set_site_location: admin or "locations" permission
create or replace function set_site_location(p_site uuid, p_lat double precision, p_lon double precision) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not store_can(s.customer_id, 'locations') then raise exception 'You don''t have permission to change location settings.'; end if;
  if p_lat is null or p_lon is null or p_lat not between -90 and 90 or p_lon not between -180 and 180 then raise exception 'That location is not valid.'; end if;
  update sites set lat = p_lat, lon = p_lon where id = p_site;
  return jsonb_build_object('ok', true, 'lat', p_lat, 'lon', p_lon);
end $$;

-- set_backup_code: admin or "locations" permission
create or replace function set_backup_code(p_site uuid, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if not (store_can(s.customer_id, 'locations') or exists (select 1 from profiles where id = auth.uid() and customer_id = s.customer_id
          and can_manage_pm and profile_sees_site(id, p_site))) then
    raise exception 'You don''t have permission to set the backup code.';
  end if;
  if p_code !~ '^[0-9]{4,8}$' then raise exception 'Use 4 to 8 digits.'; end if;
  update sites set backup_code_hash = extensions.crypt(p_code, extensions.gen_salt('bf')), backup_code_set_at = now(),
         backup_code_set_by_name = (select full_name from profiles where id = auth.uid()) where id = p_site;
end $$;

-- add_location: admin or "locations" permission
create or replace function add_location(p_name text, p_address text, p_zip text, p_lat double precision, p_lon double precision, p_timezone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); sid uuid := gen_random_uuid();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'locations') then raise exception 'You don''t have permission to add locations.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_address, ''))) < 5 then raise exception 'Enter the location''s name and address.'; end if;
  if exists (select 1 from sites where customer_id = m.customer_id and lower(name) = lower(trim(p_name))) then raise exception 'You already have a location with that name.'; end if;
  insert into sites (id, customer_id, name, address, zip, lat, lon, geofence_radius_ft, require_checkin, timezone)
    values (sid, m.customer_id, trim(p_name), trim(p_address), nullif(trim(p_zip), ''), p_lat, p_lon, 300, true, coalesce(nullif(p_timezone, ''), 'America/Chicago'));
  return jsonb_build_object('ok', true, 'site_id', sid, 'locations', (select count(*) from sites where customer_id = m.customer_id));
end $$;

-- update_location: admin or "locations" permission
create or replace function update_location(p_site uuid, p_name text, p_address text, p_zip text, p_lat double precision, p_lon double precision, p_timezone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not store_can(s.customer_id, 'locations') then raise exception 'You don''t have permission to change locations.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Enter the location name.'; end if;
  if exists (select 1 from sites where customer_id = s.customer_id and id <> s.id and lower(name) = lower(trim(p_name))) then
    raise exception 'You already have a location with that name.';
  end if;
  update sites set name = trim(p_name),
         address = coalesce(nullif(trim(p_address), ''), address),
         zip = case when nullif(trim(p_address), '') is null then zip else nullif(trim(p_zip), '') end,
         lat = case when p_lat is null then lat else p_lat end,
         lon = case when p_lon is null then lon else p_lon end,
         timezone = coalesce(nullif(p_timezone, ''), timezone)
   where id = p_site;
  return jsonb_build_object('ok', true);
end $$;

create or replace function save_equipment(p_id uuid, p_site uuid, p_type_code text, p_manufacturer text, p_model text, p_serial text,
  p_location text, p_install_date date, p_refrigerant text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites; e equipment; m profiles := me(); tid uuid;
begin
  select * into s from sites where id = p_site;
  if s.id is null or m.customer_id is distinct from s.customer_id or not store_can(m.customer_id, 'equipment') or not profile_sees_site(m.id, s.id) then
    raise exception 'You can''t change equipment for this location.';
  end if;
  if nullif(trim(p_type_code), '') is not null then
    select id into tid from equipment_types where code = p_type_code and contractor_id is null;
    if tid is null then raise exception 'Unknown equipment type.'; end if;
  end if;
  if tid is null and nullif(trim(p_manufacturer), '') is null and nullif(trim(p_model), '') is null then
    raise exception 'Pick the type or enter the make and model.';
  end if;
  if p_id is null then
    insert into equipment (customer_id, site_id, equipment_type_id, manufacturer, model, serial, refrigerant, location_description, install_date)
    values (s.customer_id, s.id, tid, nullif(trim(p_manufacturer), ''), nullif(trim(p_model), ''), nullif(trim(p_serial), ''),
            nullif(trim(p_refrigerant), ''), nullif(trim(p_location), ''), p_install_date)
    returning * into e;
  else
    update equipment set site_id = s.id, equipment_type_id = tid, manufacturer = nullif(trim(p_manufacturer), ''), model = nullif(trim(p_model), ''),
           serial = nullif(trim(p_serial), ''), refrigerant = nullif(trim(p_refrigerant), ''), location_description = nullif(trim(p_location), ''),
           install_date = p_install_date
     where id = p_id and customer_id = s.customer_id returning * into e;
    if e.id is null then raise exception 'Equipment not found.'; end if;
  end if;
  return jsonb_build_object('ok', true, 'id', e.id);
exception when unique_violation then
  raise exception 'This location already has equipment with that make and serial number.';
end $$;

create or replace function add_equipment_warranty(p_equipment uuid, p_kind text, p_starts date, p_ends date, p_description text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e equipment; m profiles := me();
begin
  select * into e from equipment where id = p_equipment;
  if e.id is null or m.customer_id is distinct from e.customer_id or not store_can(m.customer_id, 'equipment') then raise exception 'Not allowed.'; end if;
  if p_ends is null or p_ends < coalesce(p_starts, p_ends) then raise exception 'Enter when the warranty ends.'; end if;
  insert into warranties (equipment_id, kind, starts_on, ends_on, description, created_by)
  values (e.id, case when p_kind in ('manufacturer','extended','labor','parts') then p_kind else 'manufacturer' end, coalesce(p_starts, current_date), p_ends, coalesce(nullif(trim(p_description), ''), 'Warranty'), m.id);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Equipment history ----------
alter table equipment add column if not exists created_by uuid;
alter table equipment add column if not exists updated_by uuid;
alter table equipment add column if not exists updated_at timestamptz;
alter table equipment add column if not exists retired_at timestamptz;
alter table equipment add column if not exists retired_by uuid;
alter table equipment add column if not exists retired_reason text;

create table if not exists equipment_log (
  id           uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references equipment(id) on delete cascade,
  customer_id  uuid not null,
  at           timestamptz not null default now(),
  by_profile   uuid,
  by_name      text,
  action       text not null check (action in ('added','changed','warranty','removed','restored','confirmed')),
  detail       text
);
create index if not exists equipment_log_eq on equipment_log (equipment_id, at desc);
alter table equipment_log enable row level security;
revoke all on equipment_log from anon, authenticated;
grant select on equipment_log to authenticated;
create policy read_eq_log on equipment_log for select using (exists (select 1 from equipment e where e.id = equipment_id and can_see_site(e.site_id)));

create or replace function _eq_log(p_eq uuid, p_action text, p_detail text) returns void
language sql security definer set search_path = public as $$
  insert into equipment_log (equipment_id, customer_id, by_profile, by_name, action, detail)
  select e.id, e.customer_id, auth.uid(), (select full_name from profiles where id = auth.uid()), p_action, p_detail from equipment e where e.id = p_eq
$$;

create or replace function save_equipment(p_id uuid, p_site uuid, p_type_code text, p_manufacturer text, p_model text, p_serial text,
  p_location text, p_install_date date, p_refrigerant text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites; e equipment; old equipment; m profiles := me(); tid uuid; ch text;
begin
  select * into s from sites where id = p_site;
  if s.id is null or m.customer_id is distinct from s.customer_id or not store_can(m.customer_id, 'equipment') or not profile_sees_site(m.id, s.id) then
    raise exception 'You don''t have permission to change equipment for this location.';
  end if;
  if nullif(trim(p_type_code), '') is not null then
    select id into tid from equipment_types where code = p_type_code and contractor_id is null;
    if tid is null then raise exception 'Unknown equipment type.'; end if;
  end if;
  if tid is null and nullif(trim(p_manufacturer), '') is null and nullif(trim(p_model), '') is null then
    raise exception 'Pick the type or enter the make and model.';
  end if;
  if p_id is null then
    insert into equipment (customer_id, site_id, equipment_type_id, manufacturer, model, serial, refrigerant, location_description, install_date, created_by)
    values (s.customer_id, s.id, tid, nullif(trim(p_manufacturer), ''), nullif(trim(p_model), ''), nullif(trim(p_serial), ''),
            nullif(trim(p_refrigerant), ''), nullif(trim(p_location), ''), p_install_date, m.id)
    returning * into e;
    perform _eq_log(e.id, 'added', concat_ws(' ', (select name from equipment_types where id = tid), e.manufacturer, e.model, case when e.serial is not null then 'S/N ' || e.serial end));
  else
    select * into old from equipment where id = p_id and customer_id = s.customer_id;
    if old.id is null then raise exception 'Equipment not found.'; end if;
    update equipment set site_id = s.id, equipment_type_id = tid, manufacturer = nullif(trim(p_manufacturer), ''), model = nullif(trim(p_model), ''),
           serial = nullif(trim(p_serial), ''), refrigerant = nullif(trim(p_refrigerant), ''), location_description = nullif(trim(p_location), ''),
           install_date = p_install_date, updated_by = m.id, updated_at = now()
     where id = p_id returning * into e;
    ch := concat_ws('; ',
      case when old.site_id is distinct from e.site_id then 'moved to ' || s.name end,
      case when old.equipment_type_id is distinct from e.equipment_type_id then 'type' end,
      case when old.manufacturer is distinct from e.manufacturer then 'make ' || coalesce(old.manufacturer, '—') || ' → ' || coalesce(e.manufacturer, '—') end,
      case when old.model is distinct from e.model then 'model ' || coalesce(old.model, '—') || ' → ' || coalesce(e.model, '—') end,
      case when old.serial is distinct from e.serial then 'serial ' || coalesce(old.serial, '—') || ' → ' || coalesce(e.serial, '—') end,
      case when old.refrigerant is distinct from e.refrigerant then 'refrigerant' end,
      case when old.location_description is distinct from e.location_description then 'where it is' end,
      case when old.install_date is distinct from e.install_date then 'install date' end);
    if ch <> '' then perform _eq_log(e.id, 'changed', ch); end if;
  end if;
  return jsonb_build_object('ok', true, 'id', e.id);
exception when unique_violation then
  raise exception 'This location already has equipment with that make and serial number.';
end $$;

create or replace function add_equipment_warranty(p_equipment uuid, p_kind text, p_starts date, p_ends date, p_description text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e equipment; m profiles := me(); k text := case when p_kind in ('manufacturer','extended','labor','parts') then p_kind else 'manufacturer' end;
begin
  select * into e from equipment where id = p_equipment;
  if e.id is null or m.customer_id is distinct from e.customer_id or not store_can(m.customer_id, 'equipment') then raise exception 'You don''t have permission to change equipment.'; end if;
  if p_ends is null or p_ends < coalesce(p_starts, p_ends) then raise exception 'Enter when the warranty ends.'; end if;
  insert into warranties (equipment_id, kind, starts_on, ends_on, description, created_by)
  values (e.id, k, coalesce(p_starts, current_date), p_ends, coalesce(nullif(trim(p_description), ''), 'Warranty'), m.id);
  perform _eq_log(e.id, 'warranty', format('%s warranty until %s%s', k, p_ends, coalesce(': ' || nullif(trim(p_description), ''), '')));
  return jsonb_build_object('ok', true);
end $$;

-- Remove (or bring back) a unit. Nothing is erased: history and past calls stay.
create or replace function retire_equipment(p_equipment uuid, p_reason text, p_restore boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e equipment; m profiles := me();
begin
  select * into e from equipment where id = p_equipment;
  if e.id is null or m.customer_id is distinct from e.customer_id or not store_can(m.customer_id, 'equipment') then raise exception 'You don''t have permission to change equipment.'; end if;
  if coalesce(p_restore, false) then
    update equipment set retired_at = null, retired_by = null, retired_reason = null, updated_by = m.id, updated_at = now() where id = e.id;
    perform _eq_log(e.id, 'restored', null);
  else
    if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why it''s being removed (replaced, scrapped, moved out…).'; end if;
    update equipment set retired_at = now(), retired_by = m.id, retired_reason = trim(p_reason) where id = e.id;
    perform _eq_log(e.id, 'removed', trim(p_reason));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Team members with per-person permissions ----------
create or replace function _team_perms(p jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'is_org_admin', coalesce((p->>'admin')::boolean, false),
    'can_open_calls', coalesce((p->>'calls')::boolean, true),
    'can_approve', coalesce((p->>'approve')::boolean, false),
    'approval_limit', case when coalesce((p->>'approve')::boolean, false) then nullif(p->>'limit', '')::numeric end,
    'can_manage_equipment', coalesce((p->>'equipment')::boolean, false),
    'can_manage_contractors', coalesce((p->>'contractors')::boolean, false),
    'can_manage_locations', coalesce((p->>'locations')::boolean, false),
    'can_manage_team', coalesce((p->>'team')::boolean, false))
$$;

create or replace function invite_team_member(p_name text, p_email text, p_phone text, p_title text, p_perms jsonb, p_all_sites boolean, p_site_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); si jsonb; tok uuid; em text := nullif(lower(trim(p_email)), ''); pr jsonb := _team_perms(p_perms);
begin
  if m.customer_id is null or not store_can(m.customer_id, 'team') then raise exception 'You don''t have permission to add people.'; end if;
  if (pr->>'is_org_admin')::boolean and not m.is_org_admin then raise exception 'Only an admin can make someone an admin.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Enter the person''s name.'; end if;
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter their email (it becomes their sign-in).'; end if;
  if exists (select 1 from auth.users where lower(email) = em) then raise exception 'That email already has a login.'; end if;
  si := seat_info();
  if (si->>'used')::int >= (si->>'included')::int + (si->>'extra')::int then
    raise exception 'All % logins are in use (one comes with each location). Buy another login, or remove someone first.', (si->>'included')::int + (si->>'extra')::int;
  end if;
  if not (coalesce(p_all_sites, false) or (pr->>'is_org_admin')::boolean) and (coalesce(cardinality(p_site_ids), 0) = 0 or exists (select 1 from unnest(p_site_ids) x
       where not exists (select 1 from sites s where s.id = x and s.customer_id = m.customer_id))) then
    raise exception 'Pick which locations they can see.';
  end if;
  insert into join_links (kind, customer_id, full_name, email, phone, created_by, perms, expires_at)
  values ('customer_member', m.customer_id, trim(p_name), em, nullif(trim(p_phone), ''), m.id,
          pr || jsonb_build_object('title', nullif(trim(p_title), ''), 'all_sites', coalesce(p_all_sites, false) or (pr->>'is_org_admin')::boolean,
            'sites', to_jsonb(coalesce(p_site_ids, '{}'))), now() + interval '7 days')
  returning token into tok;
  return jsonb_build_object('ok', true, 'token', tok);
end $$;

create or replace function update_team_member(p_profile uuid, p_title text, p_perms jsonb, p_all_sites boolean, p_site_ids uuid[], p_active boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); p profiles; pr jsonb := _team_perms(p_perms);
begin
  select * into p from profiles where id = p_profile;
  if p.id is null or m.customer_id is null or p.customer_id is distinct from m.customer_id or not store_can(m.customer_id, 'team') then raise exception 'You don''t have permission to change people.'; end if;
  if not m.is_org_admin and (p.is_org_admin or (pr->>'is_org_admin')::boolean) then raise exception 'Only an admin can change an admin or make someone an admin.'; end if;
  if p.id = m.id and (not (pr->>'is_org_admin')::boolean and m.is_org_admin or not coalesce(p_active, true)) then raise exception 'You can''t remove your own admin access.'; end if;
  if coalesce(p_active, true) and not p.active and (seat_info()->>'used')::int >= (seat_info()->>'included')::int + (seat_info()->>'extra')::int then
    raise exception 'All logins are in use.';
  end if;
  perform _allow_internal(true);
  update profiles set title = nullif(trim(p_title), ''), is_org_admin = (pr->>'is_org_admin')::boolean, can_open_calls = (pr->>'can_open_calls')::boolean,
         can_approve = (pr->>'can_approve')::boolean, approval_limit = (pr->>'approval_limit')::numeric,
         can_manage_equipment = (pr->>'can_manage_equipment')::boolean, can_manage_contractors = (pr->>'can_manage_contractors')::boolean,
         can_manage_locations = (pr->>'can_manage_locations')::boolean, can_manage_team = (pr->>'can_manage_team')::boolean,
         can_manage_pm = (pr->>'is_org_admin')::boolean, can_see_billing = (pr->>'is_org_admin')::boolean,
         all_sites = coalesce(p_all_sites, false) or (pr->>'is_org_admin')::boolean, active = coalesce(p_active, true),
         site_ids = array(select x from unnest(coalesce(p_site_ids, '{}')) x where exists (select 1 from sites s where s.id = x and s.customer_id = m.customer_id))
   where id = p.id;
  perform _end_internal();
  return jsonb_build_object('ok', true);
end $$;

-- The sign-in link carries the permissions into the new login.
create or replace function _apply_join_perms() returns trigger
language plpgsql security definer set search_path = public as $$
declare l join_links;
begin
  if new.kind = 'customer_member' and old.used_at is null and new.used_at is not null and new.profile_id is not null then
    perform _allow_internal(true);
    update profiles set
      can_open_calls = coalesce((new.perms->>'can_open_calls')::boolean, true),
      can_manage_equipment = coalesce((new.perms->>'can_manage_equipment')::boolean, false),
      can_manage_contractors = coalesce((new.perms->>'can_manage_contractors')::boolean, false),
      can_manage_locations = coalesce((new.perms->>'can_manage_locations')::boolean, false),
      can_manage_team = coalesce((new.perms->>'can_manage_team')::boolean, false)
     where id = new.profile_id;
    perform _end_internal();
  end if;
  return null;
end $$;
create trigger join_links_perms after update on join_links for each row execute function _apply_join_perms();

-- People with the contractors / team permission see the pending invites they manage.
create policy read_join_store on join_links for select using (customer_id is not null and (
  (kind = 'contractor_owner' and store_can(customer_id, 'contractors')) or (kind = 'customer_member' and store_can(customer_id, 'team'))));

revoke execute on function _eq_log(uuid, text, text) from public, anon, authenticated;
revoke execute on function retire_equipment(uuid, text, boolean) from public, anon;
grant execute on function retire_equipment(uuid, text, boolean) to authenticated;
revoke execute on function invite_team_member(text, text, text, text, jsonb, boolean, uuid[]) from public, anon;
grant execute on function invite_team_member(text, text, text, text, jsonb, boolean, uuid[]) to authenticated;
revoke execute on function update_team_member(uuid, text, jsonb, boolean, uuid[], boolean) from public, anon;
grant execute on function update_team_member(uuid, text, jsonb, boolean, uuid[], boolean) to authenticated;

create or replace function store_unexpected_visitor(p_site uuid, p_name text, p_contractor uuid default null,
  p_company text default null, p_note text default null)
returns site_visitors language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; r site_visitors; co text; msg text; pid uuid;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not (is_customer_member(s.customer_id) and can_see_site(s.id)) then raise exception 'Not your location.'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter the person''s name.'; end if;
  if p_contractor is not null and (_cc(s.customer_id, p_contractor)).contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  co := coalesce((select name from contractors where id = p_contractor), nullif(trim(p_company), ''), 'company not given');
  insert into site_visitors (site_id, customer_id, contractor_id, visitor_name, company, note, recorded_by)
  values (s.id, s.customer_id, p_contractor, trim(p_name), co, nullif(trim(p_note), ''), m.id) returning * into r;
  msg := format('Unscheduled visit at %s: %s (%s) is on site with no trip scheduled in Service Call Proof. Recorded by %s at %s.%s',
    s.name, trim(p_name), co, m.full_name, _local(r.recorded_at, s.id, 'HH12:MI AM'), coalesce(' ' || r.note, ''));
  for pid in select p.id from profiles p where p.customer_id = s.customer_id and p.active and p.id <> m.id and profile_sees_site(p.id, s.id) loop
    perform _notify(pid, null, 'arrival', msg, 'visitor:' || r.id);
  end loop;
  if p_contractor is not null then
    for pid in select p.id from profiles p where p.contractor_id = p_contractor and p.active and (p.is_org_admin or p.can_dispatch) loop
      perform _notify(pid, null, 'arrival', msg || ' Please schedule the trip with the store and have the technician check in.', 'visitor:' || r.id);
    end loop;
  end if;
  return r;
end $$;

create or replace function _invoice_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare w work_orders; cc customer_contractors;
begin
  if new.check_result = '{}'::jsonb then return null; end if;
  select * into w from work_orders where id = new.work_order_id;
  cc := _cc(w.customer_id, w.contractor_id);
  if jsonb_array_length(coalesce(new.check_result->'visits', '[]')) = 0 then
    perform _raise_flag(w.id, 'no_recorded_visit', format('Invoice %s bills %s h, but no visit was recorded in Service Call Proof (no arrival or check-in).%s',
      new.invoice_number, new.hours_billed, case when cc.unverified_time = 'no_pay' then ' Store rule: time not verified in Service Call Proof is not paid.' else '' end), false, true);
  else
    update guardrail_flags set resolved_at = now(), resolution_note = 'Visit recorded'
     where work_order_id = w.id and flag = 'no_recorded_visit' and resolved_at is null;
  end if;
  if cc.unverified_time = 'no_pay' then
    update guardrail_flags set description = description || ' Store rule: time not verified in Service Call Proof is not paid.'
     where work_order_id = w.id and flag = 'invoice_unexplained' and resolved_at is null and description not like '%Store rule%';
  end if;
  return null;
end $$;
