-- Pilot stores: the same sign-up as pilot contractors, marked plan = 'store'.
create or replace function pilot_signup(p_company text, p_name text, p_email text, p_phone text, p_techs int, p_plan text, p_note text, p_source text default 'app')
returns jsonb language plpgsql security definer set search_path = public as $$
declare m profiles; uid uuid := auth.uid();
begin
  if uid is not null then select * into m from profiles where id = uid; end if;
  if coalesce(length(trim(p_company)), 0) < 2 or coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter your company and your name.'; end if;
  if nullif(trim(p_email), '') is null and nullif(trim(p_phone), '') is null then raise exception 'Enter an email or a phone number so we can reach you.'; end if;
  if nullif(trim(p_email), '') is not null and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address.'; end if;
  if length(coalesce(p_note, '')) > 1500 or length(p_company) > 120 or length(p_name) > 120 then raise exception 'That''s a bit long. Please shorten it.'; end if;
  if (select count(*) from pilot_interest where created_at > now() - interval '1 hour') >= 30 then raise exception 'Please try again in a little while.'; end if;
  insert into pilot_interest (profile_id, company, name, email, phone, techs, plan, note, source)
  values (m.id, trim(p_company), trim(p_name), nullif(lower(trim(p_email)), ''), nullif(trim(p_phone), ''), case when p_techs between 1 and 1000 then p_techs end,
          case when p_plan in ('base','pro','enterprise','store') then p_plan end, nullif(trim(p_note), ''), case when p_source = 'demo' then 'demo' else 'app' end);
  perform _notify(a.id, null, 'guardrail_flag', format('Pilot interest: %s (%s), %s, %s. %s', trim(p_company), trim(p_name),
      case when p_plan = 'store' then coalesce(p_techs::text, '?') || ' location(s)' else coalesce(p_techs::text, '?') || ' tech(s)' end,
      coalesce(initcap(p_plan), 'any plan'), concat_ws(' · ', nullif(trim(p_email), ''), nullif(trim(p_phone), ''))))
    from profiles a where a.is_platform_admin and a.active;
  return jsonb_build_object('ok', true);
end $$;
