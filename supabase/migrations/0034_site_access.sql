-- Who on the team sees a location: asked right after a location is added, and editable per location.
-- People with "All locations" (and admins) see every location automatically.

create or replace function site_access(p_site uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not store_can(s.customer_id, 'team') then raise exception 'You don''t have permission to change who sees locations.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.full_name, 'title', p.title,
            'automatic', p.is_org_admin or p.all_sites, 'sees', p.is_org_admin or profile_sees_site(p.id, s.id))
          order by (p.is_org_admin or p.all_sites), p.full_name)
    from profiles p where p.customer_id = s.customer_id and p.active), '[]'::jsonb);
end $$;

create or replace function set_site_access(p_site uuid, p_profiles uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites; n int;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not store_can(s.customer_id, 'team') then raise exception 'You don''t have permission to change who sees locations.'; end if;
  perform _allow_internal(true);
  update profiles p set site_ids = array_append(array_remove(coalesce(p.site_ids, array(select ps.site_id from profile_sites ps where ps.profile_id = p.id)), s.id), s.id)
   where p.customer_id = s.customer_id and not p.is_org_admin and not p.all_sites and p.id = any(coalesce(p_profiles, '{}'));
  update profiles p set site_ids = array_remove(coalesce(p.site_ids, array(select ps.site_id from profile_sites ps where ps.profile_id = p.id)), s.id)
   where p.customer_id = s.customer_id and not p.is_org_admin and not p.all_sites and not (p.id = any(coalesce(p_profiles, '{}')))
     and s.id = any(coalesce(p.site_ids, array(select ps.site_id from profile_sites ps where ps.profile_id = p.id)));
  perform _end_internal();
  select count(*) into n from profiles p where p.customer_id = s.customer_id and p.active
    and (p.is_org_admin or profile_sees_site(p.id, s.id));
  return jsonb_build_object('ok', true, 'people', n);
end $$;

revoke execute on function site_access(uuid), set_site_access(uuid, uuid[]) from public, anon;
grant execute on function site_access(uuid), set_site_access(uuid, uuid[]) to authenticated;
