-- Unexpected visitors: each location can require a vehicle plate and/or a photo; one-tap call to the contractor's office (web).
alter table sites add column if not exists visitor_require_plate boolean not null default false;
alter table sites add column if not exists visitor_require_photo boolean not null default false;
grant select (visitor_require_plate, visitor_require_photo) on sites to authenticated;
alter table site_visitors add column if not exists vehicle_plate text;
alter table site_visitors add column if not exists photo_path text;

create or replace function set_visitor_rules(p_site uuid, p_require_plate boolean, p_require_photo boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not store_can(s.customer_id, 'locations') then raise exception 'You don''t have permission to change location settings.'; end if;
  update sites set visitor_require_plate = coalesce(p_require_plate, false), visitor_require_photo = coalesce(p_require_photo, false) where id = p_site;
  return jsonb_build_object('ok', true);
end $$;

create or replace function store_visitor_log(p_site uuid, p_name text, p_contractor uuid, p_company text, p_note text, p_plate text, p_photo_path text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles := me(); s sites; r site_visitors; co text; msg text; pid uuid; pl text := nullif(upper(trim(p_plate)), '');
begin
  select * into s from sites where id = p_site;
  if s.id is null or not (is_customer_member(s.customer_id) and can_see_site(s.id)) then raise exception 'Not your location.'; end if;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter the person''s name.'; end if;
  if s.visitor_require_plate and pl is null then raise exception 'This location requires the vehicle plate.'; end if;
  if s.visitor_require_photo and nullif(trim(p_photo_path), '') is null then raise exception 'This location requires a photo.'; end if;
  if p_photo_path is not null and split_part(p_photo_path, '/', 1) <> s.customer_id::text then raise exception 'Photo not valid.'; end if;
  if p_contractor is not null and (_cc(s.customer_id, p_contractor)).contractor_id is null then raise exception 'That contractor does not serve you.'; end if;
  co := coalesce((select name from contractors where id = p_contractor), nullif(trim(p_company), ''), 'company not given');
  insert into site_visitors (site_id, customer_id, contractor_id, visitor_name, company, note, recorded_by, vehicle_plate, photo_path)
  values (s.id, s.customer_id, p_contractor, trim(p_name), co, nullif(trim(p_note), ''), m.id, pl, nullif(trim(p_photo_path), '')) returning * into r;
  msg := format('Unscheduled visit at %s: %s (%s) is on site with no trip scheduled in Service Call Proof.%s Recorded by %s at %s.%s',
    s.name, trim(p_name), co, coalesce(' Vehicle ' || pl || '.', ''), m.full_name, _local(r.recorded_at, s.id, 'HH12:MI AM'), coalesce(' ' || r.note, ''));
  for pid in select p.id from profiles p where p.customer_id = s.customer_id and p.active and p.id <> m.id and profile_sees_site(p.id, s.id) loop
    perform _notify(pid, null, 'arrival', msg, 'visitor:' || r.id);
  end loop;
  if p_contractor is not null then
    for pid in select p.id from profiles p where p.contractor_id = p_contractor and p.active and (p.is_org_admin or p.can_dispatch) loop
      perform _notify(pid, null, 'arrival', msg || ' Please schedule the trip with the store and have the technician check in.', 'visitor:' || r.id);
    end loop;
  end if;
  return jsonb_build_object('ok', true, 'id', r.id);
end $$;

revoke execute on function set_visitor_rules(uuid, boolean, boolean) from public, anon;
grant execute on function set_visitor_rules(uuid, boolean, boolean) to authenticated;
revoke execute on function store_visitor_log(uuid, text, uuid, text, text, text, text) from public, anon;
grant execute on function store_visitor_log(uuid, text, uuid, text, text, text, text) to authenticated;

-- Visitor photos: private; the store's own people add and see them (folder = the store company's id).
do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'storage' and table_name = 'buckets') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('visitor-photos', 'visitor-photos', false, 8388608, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do nothing;
    execute $p$create policy visitor_photos_read on storage.objects for select to authenticated
      using (bucket_id = 'visitor-photos' and public.is_customer_member(((storage.foldername(name))[1])::uuid))$p$;
    execute $p$create policy visitor_photos_add on storage.objects for insert to authenticated
      with check (bucket_id = 'visitor-photos' and public.is_customer_member(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;
