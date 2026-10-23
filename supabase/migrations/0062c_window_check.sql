-- The call form checks a requested time against busy hours before the call is sent
create or replace function check_call_window(p_site uuid, p_start timestamptz, p_end timestamptz) returns text
language plpgsql stable security definer set search_path = public as $$
declare b jsonb;
begin
  if not can_see_site(p_site) then raise exception 'Not allowed.'; end if;
  if p_end is not null and (p_start is null or p_end <= p_start) then return 'The time has to end after it starts.'; end if;
  if p_start is not null and p_start < now() - interval '5 minutes' then return 'That time has already passed.'; end if;
  b := _busy_between(p_site, p_start, p_end);
  if b is not null then return format('That overlaps your busy hours (%s). Pick a time outside them.', b->>'text'); end if;
  return null;
end $$;
revoke execute on function check_call_window(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function check_call_window(uuid, timestamptz, timestamptz) to authenticated;
