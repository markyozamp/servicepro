-- Company owner: the person who owns the account. No admin can take the owner's admin access away or sign them out;
-- only the owner can hand ownership to another admin. The owner is told whenever someone's admin access or sign-in
-- is changed, so a departing admin can't quietly lock the company out.
alter table customers add column if not exists owner_id uuid references profiles(id);

update customers c set owner_id = (select p.id from profiles p where p.customer_id = c.id and p.is_org_admin and p.active order by p.created_at limit 1)
 where c.owner_id is null;

create or replace function _profile_owner_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from customers where owner_id = old.id)
     and (not new.is_org_admin or not new.active or new.customer_id is distinct from old.customer_id)
     and auth.uid() is not null and auth.uid() is distinct from old.id and not is_platform_admin() then
    raise exception '% is your company''s owner. Their admin access and sign-in can''t be changed by anyone else.', old.full_name;
  end if;
  return new;
end $$;
create or replace trigger profile_owner_guard before update of is_org_admin, active, customer_id on profiles
  for each row execute function _profile_owner_guard();

create or replace function _profile_access_notice() returns trigger
language plpgsql security definer set search_path = public as $$
declare own uuid; who text; what text;
begin
  if new.customer_id is null then return null; end if;
  select owner_id into own from customers where id = new.customer_id;
  if own is null or own = auth.uid() then return null; end if;
  select full_name into who from profiles where id = auth.uid();
  what := case
    when old.is_org_admin and not new.is_org_admin then format('%s''s admin access was removed', new.full_name)
    when not old.is_org_admin and new.is_org_admin then format('%s was made an admin', new.full_name)
    when old.active and not new.active then format('%s was signed out and can no longer sign in', new.full_name)
    when not old.active and new.active then format('%s can sign in again', new.full_name)
  end;
  if what is not null then
    perform _notify(own, null, 'guardrail_flag', format('Team change: %s%s. If you didn''t expect this, check Team in Service Call Proof.', what,
      case when who is not null then ' by ' || who else '' end));
  end if;
  return null;
end $$;
create or replace trigger profile_access_notice after update of is_org_admin, active on profiles
  for each row when (old.is_org_admin is distinct from new.is_org_admin or old.active is distinct from new.active)
  execute function _profile_access_notice();

create or replace function _customer_first_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.customer_id is not null and new.is_org_admin then
    update customers set owner_id = new.id where id = new.customer_id and owner_id is null;
  end if;
  return null;
end $$;
create or replace trigger customer_first_owner after insert or update of is_org_admin on profiles
  for each row execute function _customer_first_owner();

create or replace function transfer_ownership(p_profile uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m profiles := me(); t profiles;
begin
  if m.customer_id is null or not exists (select 1 from customers where id = m.customer_id and owner_id = m.id) then
    raise exception 'Only the company owner can hand over ownership.';
  end if;
  select * into t from profiles where id = p_profile;
  if t.id is null or t.customer_id is distinct from m.customer_id or not t.active then raise exception 'Pick someone on your team.'; end if;
  if not t.is_org_admin then raise exception 'Make them an admin first, then hand over ownership.'; end if;
  update customers set owner_id = t.id where id = m.customer_id;
  perform _notify(t.id, null, 'guardrail_flag', format('%s made you the owner of your company''s Service Call Proof account.', m.full_name));
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function _profile_owner_guard(), _profile_access_notice(), _customer_first_owner() from public, anon, authenticated;
revoke execute on function transfer_ownership(uuid) from public, anon;
grant execute on function transfer_ownership(uuid) to authenticated;
