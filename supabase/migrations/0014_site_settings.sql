-- ServicePro 0014 — Location settings the store controls: guest Wi-Fi for technicians, emergency limit.
-- The Wi-Fi password is kept apart from the location record: only the store's own people and a technician
-- with an open visit at that location can read it (it reaches the tech inside their job download).

create table site_wifi (
  site_id     uuid primary key references sites(id) on delete cascade,
  ssid        text,
  password    text,
  updated_by  uuid references profiles(id),
  updated_at  timestamptz not null default now()
);
alter table site_wifi enable row level security;
revoke all on site_wifi from anon, authenticated;
grant select on site_wifi to authenticated;
create policy read_wifi on site_wifi for select using (
  exists (select 1 from sites s where s.id = site_id and is_customer_member(s.customer_id) and can_see_site(s.id))
  or exists (select 1 from visits v join work_orders w on w.id = v.work_order_id
             where w.site_id = site_wifi.site_id and v.technician_id = auth.uid() and v.status in ('assigned','en_route','on_site')));

create or replace function set_site_settings(p_site uuid, p_emergency_limit numeric default null,
  p_wifi_ssid text default null, p_wifi_password text default null) returns sites
language plpgsql security definer set search_path = public as $$
declare s sites;
begin
  select * into s from sites where id = p_site;
  if s.id is null or not is_customer_admin(s.customer_id) then raise exception 'Only your company''s admin can change location settings.'; end if;
  if p_emergency_limit is not null and p_emergency_limit < 0 then raise exception 'The emergency limit cannot be negative.'; end if;
  update sites set emergency_limit = p_emergency_limit where id = p_site returning * into s;
  insert into site_wifi (site_id, ssid, password, updated_by)
  values (p_site, nullif(trim(p_wifi_ssid), ''), case when nullif(trim(p_wifi_ssid), '') is null then null else nullif(p_wifi_password, '') end, auth.uid())
  on conflict (site_id) do update set ssid = excluded.ssid, password = excluded.password, updated_by = excluded.updated_by, updated_at = now();
  return s;
end $$;
grant execute on function set_site_settings(uuid, numeric, text, text) to authenticated;
