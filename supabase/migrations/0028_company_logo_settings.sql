-- Company logo (optional, shown top-left), "Settings & plan" permission, and who may change it.
alter table customers add column if not exists logo_data text;
alter table customers add constraint customers_logo_size check (logo_data is null or (length(logo_data) < 400000 and logo_data like 'data:image/%'));
alter table profiles add column if not exists can_manage_company boolean not null default false;

create or replace function store_can(p_customer uuid, p_perm text) returns boolean
language sql stable security definer set search_path = public as $$
  select is_platform_admin() or exists (select 1 from profiles p where p.id = auth.uid() and p.active and p.customer_id = p_customer and (
    p.is_org_admin or case p_perm
      when 'equipment'   then p.can_manage_equipment or p.can_manage_pm
      when 'contractors' then p.can_manage_contractors
      when 'locations'   then p.can_manage_locations
      when 'team'        then p.can_manage_team
      when 'company'     then p.can_manage_company
      when 'calls'       then p.can_open_calls
      else false end))
$$;

create or replace function update_company(p_name text, p_phone text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'company') then raise exception 'You don''t have permission to change the company profile.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Enter the company name.'; end if;
  if nullif(trim(p_email), '') is not null and lower(trim(p_email)) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email.'; end if;
  update customers set name = trim(p_name), phone = nullif(trim(p_phone), ''), email = nullif(lower(trim(p_email)), '') where id = m.customer_id;
  return jsonb_build_object('ok', true);
end $$;


create or replace function set_company_logo(p_data text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'company') then raise exception 'You don''t have permission to change the company profile.'; end if;
  if p_data is not null and (p_data not like 'data:image/png;base64,%' and p_data not like 'data:image/jpeg;base64,%' and p_data not like 'data:image/webp;base64,%' and p_data not like 'data:image/svg+xml;base64,%') then
    raise exception 'Use a PNG, JPG or SVG image.';
  end if;
  if length(coalesce(p_data, '')) >= 400000 then raise exception 'That image is too large. Use one under about 250 KB.'; end if;
  update customers set logo_data = p_data where id = m.customer_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function set_company_logo(text) from public, anon;
grant execute on function set_company_logo(text) to authenticated;

create or replace function _team_perms(p jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'is_org_admin', coalesce((p->>'admin')::boolean, false),
    'can_open_calls', coalesce((p->>'calls')::boolean, true),
    'can_approve', coalesce((p->>'approve')::boolean, false),
    'approval_limit', case when coalesce((p->>'approve')::boolean, false) then nullif(p->>'limit', '')::numeric end,
    'can_manage_equipment', coalesce((p->>'equipment')::boolean, false),
    'can_manage_contractors', coalesce((p->>'contractors')::boolean, false),
    'can_manage_locations', coalesce((p->>'locations')::boolean, false),
    'can_manage_team', coalesce((p->>'team')::boolean, false),
    'can_manage_company', coalesce((p->>'company')::boolean, false))
$$;

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
         can_manage_company = (pr->>'can_manage_company')::boolean,
         can_manage_pm = (pr->>'is_org_admin')::boolean, can_see_billing = (pr->>'is_org_admin')::boolean,
         all_sites = coalesce(p_all_sites, false) or (pr->>'is_org_admin')::boolean, active = coalesce(p_active, true),
         site_ids = array(select x from unnest(coalesce(p_site_ids, '{}')) x where exists (select 1 from sites s where s.id = x and s.customer_id = m.customer_id))
   where id = p.id;
  perform _end_internal();
  return jsonb_build_object('ok', true);
end $$;

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
      can_manage_team = coalesce((new.perms->>'can_manage_team')::boolean, false),
      can_manage_company = coalesce((new.perms->>'can_manage_company')::boolean, false)
     where id = new.profile_id;
    perform _end_internal();
  end if;
  return null;
end $$;
