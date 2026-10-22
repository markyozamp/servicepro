-- New store customers set themselves up from a start link, and add their own locations.
alter table join_links drop constraint if exists join_links_kind_check;
alter table join_links add constraint join_links_kind_check check (kind in ('contractor_owner','contractor_member','relink','customer_start'));

-- Platform (Service Call Proof) creates a start link for a store that bought the product.
create or replace function create_start_link(p_note text default null, p_days int default 14) returns uuid
language plpgsql security definer set search_path = public as $$
declare tok uuid;
begin
  if not is_platform_admin() and current_user not in ('postgres', 'supabase_admin') then raise exception 'Not allowed.'; end if;
  insert into join_links (kind, full_name, expires_at) values ('customer_start', p_note, now() + make_interval(days => greatest(1, least(p_days, 60))))
  returning token into tok;
  return tok;
end $$;

-- The store owner fills in the start page: company, themselves, password, first location.
create or replace function start_customer(p_token uuid, p_company text, p_owner_name text, p_email text, p_phone text, p_password text,
  p_site_name text, p_address text, p_zip text, p_lat double precision, p_lon double precision, p_timezone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l join_links; cid uuid := gen_random_uuid(); sid uuid := gen_random_uuid(); uid uuid; ch uuid := gen_random_uuid(); em text := lower(trim(coalesce(p_email, '')));
begin
  select * into l from join_links where token = p_token and kind = 'customer_start' for update;
  if l.token is null then raise exception 'This link is not valid.'; end if;
  if l.used_at is not null then raise exception 'This link was already used. Sign in with the email and password you chose.'; end if;
  if l.expires_at < now() then raise exception 'This link has expired. Ask Service Call Proof for a new one.'; end if;
  if length(trim(coalesce(p_company, ''))) < 2 then raise exception 'Enter your company name.'; end if;
  if length(trim(coalesce(p_owner_name, ''))) < 2 then raise exception 'Enter your name.'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email.'; end if;
  if length(coalesce(p_password, '')) < 10 then raise exception 'Use a password of at least 10 characters.'; end if;
  if length(trim(coalesce(p_site_name, ''))) < 2 or length(trim(coalesce(p_address, ''))) < 5 then raise exception 'Enter your first location''s name and address.'; end if;
  perform _allow_internal(true);
  insert into customers (id, name, kind, phone, email, letter_escalation_at) values (cid, trim(p_company), 'commercial', nullif(trim(p_phone), ''), em, 3);
  insert into sites (id, customer_id, name, address, zip, lat, lon, geofence_radius_ft, require_checkin, timezone)
    values (sid, cid, trim(p_site_name), trim(p_address), nullif(trim(p_zip), ''), p_lat, p_lon, 300, true, coalesce(nullif(p_timezone, ''), 'America/Chicago'));
  uid := _make_login(em, p_password, trim(p_owner_name));
  insert into profiles (id, org_kind, customer_id, full_name, title, email, phone, is_org_admin, is_technician, can_dispatch, can_bill,
                        can_open_calls, can_approve, approval_limit, can_manage_pm, can_see_billing, all_sites)
    values (uid, 'customer', cid, trim(p_owner_name), 'Owner', em, nullif(trim(p_phone), ''), true, false, false, false, true, true, null, true, true, true);
  insert into approval_chains (id, customer_id, name, all_sites, timeout_minutes, emergency_profile_id) values (ch, cid, 'All locations', true, 30, uid);
  insert into approval_chain_steps (chain_id, step_no, profile_id) values (ch, 1, uid);
  update join_links set used_at = now(), customer_id = cid, profile_id = uid, email = em where token = l.token;
  perform _end_internal();
  return jsonb_build_object('ok', true, 'email', em, 'customer_id', cid);
end $$;

-- Store admin adds another location (map point and time zone come from the address lookup on the website).
create or replace function add_location(p_name text, p_address text, p_zip text, p_lat double precision, p_lon double precision, p_timezone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); sid uuid := gen_random_uuid();
begin
  if m.customer_id is null or not is_customer_admin(m.customer_id) then raise exception 'Only your company''s admin can add locations.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_address, ''))) < 5 then raise exception 'Enter the location''s name and address.'; end if;
  if exists (select 1 from sites where customer_id = m.customer_id and lower(name) = lower(trim(p_name))) then raise exception 'You already have a location with that name.'; end if;
  insert into sites (id, customer_id, name, address, zip, lat, lon, geofence_radius_ft, require_checkin, timezone)
    values (sid, m.customer_id, trim(p_name), trim(p_address), nullif(trim(p_zip), ''), p_lat, p_lon, 300, true, coalesce(nullif(p_timezone, ''), 'America/Chicago'));
  return jsonb_build_object('ok', true, 'site_id', sid, 'locations', (select count(*) from sites where customer_id = m.customer_id));
end $$;

revoke execute on function create_start_link(text, int) from public, anon, authenticated;
revoke execute on function start_customer(uuid, text, text, text, text, text, text, text, text, double precision, double precision, text) from public;
grant execute on function start_customer(uuid, text, text, text, text, text, text, text, text, double precision, double precision, text) to anon, authenticated;
revoke execute on function add_location(text, text, text, double precision, double precision, text) from public, anon;
grant execute on function add_location(text, text, text, double precision, double precision, text) to authenticated;
