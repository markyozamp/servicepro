-- The store's admin sets the location's map point by standing at the store and tapping "Use where I'm standing".
create or replace function set_site_location(p_site uuid, p_lat double precision, p_lon double precision) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not is_customer_admin(s.customer_id) then raise exception 'Only your company''s admin can change location settings.'; end if;
  if p_lat is null or p_lon is null or p_lat not between -90 and 90 or p_lon not between -180 and 180 then raise exception 'That location is not valid.'; end if;
  update sites set lat = p_lat, lon = p_lon where id = p_site;
  return jsonb_build_object('ok', true, 'lat', p_lat, 'lon', p_lon);
end $$;
revoke execute on function set_site_location(uuid, double precision, double precision) from public, anon;
grant execute on function set_site_location(uuid, double precision, double precision) to authenticated;
