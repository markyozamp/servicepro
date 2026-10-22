-- "Forgot password?": the website asks for a reset (with the server key), emails a one-time link (1 hour),
-- and the person sets a new password from that link.
create table if not exists password_resets (
  token_hash  text primary key,
  user_id     uuid not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '1 hour',
  used_at     timestamptz
);
alter table password_resets enable row level security;
revoke all on password_resets from anon, authenticated;

create or replace function request_password_reset(p_key text, p_email text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid; nm text; tok text;
begin
  if p_key is null or p_key is distinct from (select value from app_secrets where name = 'outbox') then raise exception 'Not allowed.'; end if;
  select u.id, p.full_name into uid, nm from auth.users u join profiles p on p.id = u.id
   where lower(u.email) = lower(trim(p_email)) and coalesce(p.active, true);
  if uid is null then return jsonb_build_object('ok', false); end if;
  if (select count(*) from password_resets where user_id = uid and created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'limited', true);
  end if;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into password_resets (token_hash, user_id) values (encode(sha256(convert_to(tok, 'UTF8')), 'hex'), uid);
  return jsonb_build_object('ok', true, 'token', tok, 'name', nm);
end $$;

create or replace function reset_password_with_token(p_token text, p_password text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r password_resets; em text;
begin
  select * into r from password_resets where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') for update;
  if r.token_hash is null or r.used_at is not null or r.expires_at < now() then
    raise exception 'This reset link is not valid anymore. Ask for a new one from the sign-in page.';
  end if;
  if length(coalesce(p_password, '')) < 10 then raise exception 'Use at least 10 characters.'; end if;
  perform _set_password(r.user_id, p_password);
  update password_resets set used_at = now() where token_hash = r.token_hash;
  update password_resets set used_at = now() where user_id = r.user_id and used_at is null;
  select email into em from auth.users where id = r.user_id;
  return jsonb_build_object('ok', true, 'email', em);
end $$;

revoke execute on function request_password_reset(text, text) from public, authenticated;
grant execute on function request_password_reset(text, text) to anon;
revoke execute on function reset_password_with_token(text, text) from public;
grant execute on function reset_password_with_token(text, text) to anon, authenticated;
