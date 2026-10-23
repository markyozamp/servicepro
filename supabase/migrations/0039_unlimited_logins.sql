-- Logins are unlimited (Mark, 2026-10-23): no per-login fee. Heavier use is covered by the fair-use message credits.
-- seat_info() still reports how many people are on the team; it never blocks adding someone.
create or replace function seat_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'unlimited', true,
    'included', 1000000,
    'extra', 0,
    'used', (select count(*) from profiles where customer_id = m.customer_id and active)
          + (select count(*) from join_links where customer_id = m.customer_id and kind = 'customer_member' and used_at is null and expires_at > now()))
  from (select * from me()) m
$$;
