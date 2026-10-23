-- What each customer calls its places (stores, restaurants, facilities, properties, homes, or just locations).
-- Chosen at setup and changeable in Settings; the customer's screens use it. Contractor-facing text stays neutral.
alter table customers add column if not exists place_word text not null default 'location'
  check (place_word in ('location', 'store', 'restaurant', 'facility', 'property', 'home'));

-- Sensible starting words for accounts that already exist
do $$ begin
perform set_config('app.demo_guard_off', 'on', true);
update customers set place_word = 'property' where kind = 'property_manager' and place_word = 'location';
update customers set place_word = 'home' where kind = 'residential' and place_word = 'location';
update customers set place_word = 'store' where place_word = 'location' and (name ilike '%grocer%' or name ilike '%market%' or name ilike '%(demo)');
perform set_config('app.demo_guard_off', 'off', true);
end $$;

create or replace function set_place_word(p_word text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me();
begin
  if m.customer_id is null or not store_can(m.customer_id, 'company') then raise exception 'You don''t have permission to change company settings.'; end if;
  if _demo_actor() then raise exception 'This is the demo, so that change is turned off. It works in your own account.'; end if;
  if p_word is null or p_word not in ('location', 'store', 'restaurant', 'facility', 'property', 'home') then raise exception 'Pick one of the choices.'; end if;
  perform _allow_internal(true);
  update customers set place_word = p_word where id = m.customer_id;
  perform _end_internal();
  return jsonb_build_object('ok', true, 'word', p_word);
end $$;
revoke execute on function set_place_word(text) from public, anon;
grant execute on function set_place_word(text) to authenticated;
