-- ServicePro 0013 — Don't trust the phone's clock blindly.
-- 1. Every time the phone syncs it reports its own clock. If it is more than 2 minutes off the server,
--    the tech is told to fix it and the contractor office is told (once a day), with the amount.
-- 2. A time from the phone can never be earlier than the last time that phone talked to the server:
--    anything done offline happened after the last contact, so a clock set back can't move times earlier.

alter table profiles
  add column device_last_seen_at timestamptz,          -- server time of the phone's last successful sync
  add column device_clock_offset_s int;                -- phone clock minus server clock at that sync

create table device_clock_checks (
  id          bigint generated always as identity primary key,
  profile_id  uuid not null references profiles(id) on delete cascade,
  checked_at  timestamptz not null default now(),
  device_time timestamptz not null,
  offset_s    int not null
);
create index on device_clock_checks (profile_id, checked_at desc);
alter table device_clock_checks enable row level security;
revoke all on device_clock_checks from anon, authenticated;
grant select on device_clock_checks to authenticated;
create policy read_clock on device_clock_checks for select using (profile_id = auth.uid() or is_platform_admin()
  or exists (select 1 from profiles t where t.id = profile_id and is_contractor_office(t.contractor_id)));

-- The phone calls this after sending its saved actions, at every sync.
create or replace function device_hello(p_device_now timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); off int; p record;
begin
  if m.id is null then raise exception 'Not signed in.'; end if;
  off := round(extract(epoch from (p_device_now - now())));
  update profiles set device_last_seen_at = now(), device_clock_offset_s = off where id = m.id;
  insert into device_clock_checks (profile_id, device_time, offset_s) values (m.id, p_device_now, off);
  if abs(off) > 120 and m.contractor_id is not null then
    for p in select id from profiles where contractor_id = m.contractor_id and active and (is_org_admin or can_dispatch) loop
      perform _notify(p.id, null, 'guardrail_flag', format('%s''s phone clock is %s min %s. Times from that phone may be wrong until it''s fixed.',
        m.full_name, abs(off) / 60, case when off > 0 then 'fast' else 'slow' end), 'clock:' || m.id || ':' || current_date);
    end loop;
  end if;
  return jsonb_build_object('server_now', now(), 'offset_s', off, 'ok', abs(off) <= 120);
end $$;

create or replace function _device_time(p_at timestamptz) returns timestamptz
language plpgsql stable set search_path = public as $$
declare last_seen timestamptz;
begin
  if p_at is null then return now(); end if;
  if p_at > now() + interval '5 minutes' then
    raise exception 'Device clock is ahead of server time (%). Check the phone''s date/time settings.', p_at;
  end if;
  if p_at < now() - interval '7 days' then
    raise exception 'Timestamp % is more than 7 days old; the office must enter a time correction.', p_at;
  end if;
  -- Done offline means done after the phone's last contact with the server.
  select device_last_seen_at into last_seen from profiles where id = auth.uid();
  if last_seen is not null and p_at < last_seen - interval '1 minute' then
    return last_seen;
  end if;
  return least(p_at, now());
end $$;

grant execute on function device_hello(timestamptz) to authenticated;
