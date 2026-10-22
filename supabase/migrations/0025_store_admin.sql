-- Store admin tools: company profile, edit locations, backup-code status, store equipment, store team logins (seats).

-- ---------- Backup code: who set it and when (the code itself stays hashed) ----------
alter table sites add column if not exists backup_code_set_at timestamptz;
alter table sites add column if not exists backup_code_set_by_name text;
grant select (backup_code_set_at, backup_code_set_by_name) on sites to authenticated;

create or replace function set_backup_code(p_site uuid, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if not (is_customer_admin(s.customer_id) or exists (select 1 from profiles where id = auth.uid() and customer_id = s.customer_id
          and can_manage_pm and profile_sees_site(id, p_site))) then
    raise exception 'Only the store''s administrator can set the backup code.';
  end if;
  if p_code !~ '^[0-9]{4,8}$' then raise exception 'Use 4 to 8 digits.'; end if;
  update sites set backup_code_hash = extensions.crypt(p_code, extensions.gen_salt('bf')), backup_code_set_at = now(),
         backup_code_set_by_name = (select full_name from profiles where id = auth.uid()) where id = p_site;
end $$;

-- ---------- Company profile and locations ----------
create or replace function update_company(p_name text, p_phone text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not is_customer_admin(m.customer_id) then raise exception 'Only your company''s admin can change the company profile.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Enter the company name.'; end if;
  if nullif(trim(p_email), '') is not null and lower(trim(p_email)) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email.'; end if;
  update customers set name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), '') where id = m.customer_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function update_location(p_site uuid, p_name text, p_address text, p_zip text, p_lat double precision, p_lon double precision, p_timezone text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not is_customer_admin(s.customer_id) then raise exception 'Only your company''s admin can change locations.'; end if;
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

-- ---------- Store equipment ----------
alter table warranties alter column work_order_id drop not null;
alter table warranties drop constraint if exists warranties_kind_check;
alter table warranties add constraint warranties_kind_check check (kind in ('labor','parts','manufacturer','extended'));

create or replace function save_equipment(p_id uuid, p_site uuid, p_type_code text, p_manufacturer text, p_model text, p_serial text,
  p_location text, p_install_date date, p_refrigerant text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites; e equipment; m profiles := me(); tid uuid;
begin
  select * into s from sites where id = p_site;
  if s.id is null or m.customer_id is distinct from s.customer_id or not (m.is_org_admin or m.can_manage_pm) or not profile_sees_site(m.id, s.id) then
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
  if e.id is null or m.customer_id is distinct from e.customer_id or not (m.is_org_admin or m.can_manage_pm) then raise exception 'Not allowed.'; end if;
  if p_ends is null or p_ends < coalesce(p_starts, p_ends) then raise exception 'Enter when the warranty ends.'; end if;
  insert into warranties (equipment_id, kind, starts_on, ends_on, description, created_by)
  values (e.id, case when p_kind in ('manufacturer','extended','labor','parts') then p_kind else 'manufacturer' end, coalesce(p_starts, current_date), p_ends, coalesce(nullif(trim(p_description), ''), 'Warranty'), m.id);
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Store team logins (seats) ----------
-- Which locations a store person sees: profiles.site_ids when set (managed from the Team screen), else the older profile_sites rows.
alter table profiles add column if not exists site_ids uuid[];
create or replace function profile_sees_site(p_profile uuid, p_site uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles p join sites s on s.id = p_site
    where p.id = p_profile and p.active and (
         p.is_platform_admin
      or (p.customer_id = s.customer_id and (p.all_sites
            or (p.site_ids is not null and s.id = any(p.site_ids))
            or (p.site_ids is null and exists (select 1 from profile_sites ps where ps.profile_id = p.id and ps.site_id = s.id))))
      or (p.contractor_id is not null and exists (
            select 1 from customer_contractors cc where cc.contractor_id = p.contractor_id and cc.customer_id = s.customer_id))))
$$;
-- Each location includes one login; the whole company shares the pool. Extra logins: $25/year (bought later through billing).
alter table customers add column if not exists extra_seats int not null default 0;

create or replace function seat_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'included', (select count(*) from sites where customer_id = m.customer_id),
    'extra', (select extra_seats from customers where id = m.customer_id),
    'used', (select count(*) from profiles where customer_id = m.customer_id and active)
          + (select count(*) from join_links where customer_id = m.customer_id and kind = 'customer_member' and used_at is null and expires_at > now()))
  from (select * from me()) m
$$;

create or replace function invite_store_user(p_name text, p_email text, p_phone text, p_title text, p_admin boolean, p_can_approve boolean,
  p_approval_limit numeric, p_all_sites boolean, p_site_ids uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); si jsonb; tok uuid; em text := nullif(lower(trim(p_email)), '');
begin
  if m.customer_id is null or not is_customer_admin(m.customer_id) then raise exception 'Only your company''s admin can add people.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Enter the person''s name.'; end if;
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter their email (it becomes their sign-in).'; end if;
  if exists (select 1 from auth.users where lower(email) = em) then raise exception 'That email already has a login.'; end if;
  si := seat_info();
  if (si->>'used')::int >= (si->>'included')::int + (si->>'extra')::int then
    raise exception 'All % logins are in use (one comes with each location). Buy another login, or remove someone first.', (si->>'included')::int + (si->>'extra')::int;
  end if;
  if not coalesce(p_all_sites, false) and (coalesce(cardinality(p_site_ids), 0) = 0 or exists (select 1 from unnest(p_site_ids) x
       where not exists (select 1 from sites s where s.id = x and s.customer_id = m.customer_id))) then
    raise exception 'Pick which locations they can see.';
  end if;
  insert into join_links (kind, customer_id, full_name, email, phone, created_by, perms, expires_at)
  values ('customer_member', m.customer_id, trim(p_name), em, nullif(trim(p_phone), ''), m.id,
          jsonb_build_object('title', nullif(trim(p_title), ''), 'is_org_admin', coalesce(p_admin, false), 'can_approve', coalesce(p_can_approve, false),
            'approval_limit', p_approval_limit, 'all_sites', coalesce(p_all_sites, false) or coalesce(p_admin, false),
            'sites', to_jsonb(coalesce(p_site_ids, '{}'))), now() + interval '7 days')
  returning token into tok;
  return jsonb_build_object('ok', true, 'token', tok);
end $$;

create or replace function update_store_user(p_profile uuid, p_title text, p_admin boolean, p_can_approve boolean, p_approval_limit numeric,
  p_all_sites boolean, p_site_ids uuid[], p_active boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); p profiles;
begin
  select * into p from profiles where id = p_profile;
  if p.id is null or m.customer_id is null or p.customer_id is distinct from m.customer_id or not is_customer_admin(m.customer_id) then raise exception 'Not allowed.'; end if;
  if p.id = m.id and (not coalesce(p_admin, true) or not coalesce(p_active, true)) then raise exception 'You can''t remove your own admin access.'; end if;
  if coalesce(p_active, true) and not p.active then
    if ((seat_info()->>'used')::int >= (seat_info()->>'included')::int + (seat_info()->>'extra')::int) then raise exception 'All logins are in use.'; end if;
  end if;
  perform _allow_internal(true);
  update profiles set title = nullif(trim(p_title), ''), is_org_admin = coalesce(p_admin, false), can_approve = coalesce(p_can_approve, false),
         approval_limit = p_approval_limit, all_sites = coalesce(p_all_sites, false) or coalesce(p_admin, false), active = coalesce(p_active, true),
         can_open_calls = true, can_manage_pm = coalesce(p_admin, false), can_see_billing = coalesce(p_admin, false),
         site_ids = array(select x from unnest(coalesce(p_site_ids, '{}')) x
                          where exists (select 1 from sites s where s.id = x and s.customer_id = m.customer_id))
   where id = p.id;
  perform _end_internal();
  return jsonb_build_object('ok', true);
end $$;

-- Sign-in links now also create store team logins.
create or replace function join_redeem(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l join_links; pw text := encode(extensions.gen_random_bytes(24), 'base64'); em text; uid uuid; p profiles;
begin
  select * into l from join_links where token = p_token for update;
  if l.token is null then raise exception 'This link is not valid.'; end if;
  if l.used_at is not null then raise exception 'This link was already used. Ask for a new one.'; end if;
  if l.expires_at < now() then raise exception 'This link has expired. Ask for a new one.'; end if;
  if l.kind = 'customer_start' then raise exception 'This link is for setting up a new account.'; end if;

  if l.kind = 'relink' then
    select * into p from profiles where id = l.profile_id;
    if p.id is null or not p.active then raise exception 'This login is no longer active.'; end if;
    em := (select email from auth.users where id = p.id);
    perform _set_password(p.id, pw);
  elsif l.kind = 'customer_member' then
    em := l.email;
    uid := _make_login(em, pw, l.full_name);
    insert into profiles (id, org_kind, customer_id, full_name, title, email, phone, is_org_admin, is_technician, can_dispatch, can_bill,
                          can_open_calls, can_approve, approval_limit, can_manage_pm, can_see_billing, all_sites, site_ids)
    values (uid, 'customer', l.customer_id, l.full_name, l.perms->>'title', l.email, l.phone, coalesce((l.perms->>'is_org_admin')::boolean, false),
            false, false, false, true, coalesce((l.perms->>'can_approve')::boolean, false), nullif(l.perms->>'approval_limit', '')::numeric,
            coalesce((l.perms->>'is_org_admin')::boolean, false), coalesce((l.perms->>'is_org_admin')::boolean, false),
            coalesce((l.perms->>'all_sites')::boolean, false),
            array(select x::uuid from jsonb_array_elements_text(coalesce(l.perms->'sites', '[]'::jsonb)) x
                   where exists (select 1 from sites s where s.id = x::uuid and s.customer_id = l.customer_id)))
    returning * into p;
  else
    em := coalesce(l.email, 'u' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 16) || '@users.servicepro.app');
    uid := _make_login(em, pw, l.full_name);
    insert into profiles (id, org_kind, contractor_id, full_name, email, phone, is_org_admin, can_dispatch, can_bill, is_technician)
    values (uid, 'contractor', l.contractor_id, l.full_name, l.email, l.phone,
            coalesce((l.perms->>'is_org_admin')::boolean, false), coalesce((l.perms->>'can_dispatch')::boolean, false),
            coalesce((l.perms->>'can_bill')::boolean, false), coalesce((l.perms->>'is_technician')::boolean, false))
    returning * into p;
  end if;
  update join_links set used_at = now(), profile_id = p.id where token = l.token;
  return jsonb_build_object('email', em, 'password', pw, 'is_technician', p.is_technician, 'name', p.full_name);
end $$;

alter table join_links drop constraint if exists join_links_kind_check;
alter table join_links add constraint join_links_kind_check check (kind in ('contractor_owner','contractor_member','relink','customer_start','customer_member'));

revoke execute on function update_company(text, text, text) from public, anon;
grant execute on function update_company(text, text, text) to authenticated;
revoke execute on function update_location(uuid, text, text, text, double precision, double precision, text) from public, anon;
grant execute on function update_location(uuid, text, text, text, double precision, double precision, text) to authenticated;
revoke execute on function save_equipment(uuid, uuid, text, text, text, text, text, date, text) from public, anon;
grant execute on function save_equipment(uuid, uuid, text, text, text, text, text, date, text) to authenticated;
revoke execute on function add_equipment_warranty(uuid, text, date, date, text) from public, anon;
grant execute on function add_equipment_warranty(uuid, text, date, date, text) to authenticated;
revoke execute on function seat_info() from public, anon;
grant execute on function seat_info() to authenticated;
revoke execute on function invite_store_user(text, text, text, text, boolean, boolean, numeric, boolean, uuid[]) from public, anon;
grant execute on function invite_store_user(text, text, text, text, boolean, boolean, numeric, boolean, uuid[]) to authenticated;
revoke execute on function update_store_user(uuid, text, boolean, boolean, numeric, boolean, uuid[], boolean) from public, anon;
grant execute on function update_store_user(uuid, text, boolean, boolean, numeric, boolean, uuid[], boolean) to authenticated;
