-- ServicePro 0012 — Wrong check-in code: simply try again.
-- A wrong code is NOT a check-in (the door alarm keeps going). Tries 1–2: "wrong code, try again", nothing
-- flagged. Third wrong try: the store and the contractor office are told, it's noted on the call, and the
-- tech is pointed to the store's backup code or "no code available". The tech can keep trying the right code.

alter table visits add column checkin_attempts int not null default 0;

create or replace function tech_checkin(p_visit uuid, p_method checkin_method, p_code text default null,
 p_person text default null, p_reason text default null, p_at timestamptz default null, p_checkout boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v visits := _my_visit(p_visit); t timestamptz := _device_time(p_at); w work_orders; s sites; ok boolean; what text; tries int;
begin
 if v.arrived_at is null then raise exception 'Arrive on site first.'; end if;
 if not p_checkout and v.checkin_at is not null and v.checkin_verified then
 return jsonb_build_object('ok', true, 'already', true, 'verified', true);
 end if;
 if p_checkout and v.checkout_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
 select * into w from work_orders where id = v.work_order_id;
 select * into s from sites where id = w.site_id;
 what := case when p_checkout then 'Check-out' else 'Check-in' end;

 if p_method in ('code', 'backup_code') then
   if p_method = 'code' then
     ok := exists (select 1 from visit_codes c where c.visit_id = v.id and c.code = trim(p_code));
   else
     if s.backup_code_hash is null then raise exception 'This store has no backup code set.'; end if;
     ok := s.backup_code_hash = extensions.crypt(trim(p_code), s.backup_code_hash);
   end if;
   if not ok then
     update visits set checkin_attempts = checkin_attempts + 1 where id = v.id returning checkin_attempts into tries;
     if tries = 3 then
       perform _raise_flag(w.id, 'checkin_unverified', format('%s: wrong code entered 3 times.', what), false, true);
       perform _notify_customer(w.id, 'checkin', format('Call #%s: the technician has entered a wrong check-in code 3 times. Please check the code with them.', w.number),
         'badcode:' || v.id);
       perform _notify_office(w.id, 'checkin', format('Call #%s: %s entered a wrong check-in code 3 times at %s.', w.number,
         (select full_name from profiles where id = v.technician_id), s.name), 'badcode:' || v.id);
     end if;
     return jsonb_build_object('ok', true, 'verified', false, 'attempts', tries,
       'message', case when tries < 3 then format('Wrong code — check it with the store person and try again (%s of 3).', tries)
                       else 'Wrong code again. The store and your office have been told. Check the code with the store person, or use the store''s backup code or "No code available".' end);
   end if;
   if p_checkout then
     update visits set checkout_at = greatest(t, arrived_at), checkout_method = p_method where id = v.id;
   else
     update visits set checkin_at = coalesce(checkin_at, greatest(t, arrived_at)), checkin_method = p_method, checkin_verified = true,
       checkin_person = null, checkin_reason = null where id = v.id;
   end if;
   update guardrail_flags set resolved_at = now(), resolution_note = 'Verified with the right code'
    where work_order_id = w.id and flag = 'checkin_unverified' and resolved_at is null and not p_checkout
      and description not like '%waited%';
   perform _notify_customer(w.id, 'checkin', format('%s confirmed for call #%s%s.', what, w.number,
     case when p_method = 'backup_code' then ' (store backup code used)' else '' end));
   return jsonb_build_object('ok', true, 'verified', true);
 end if;

 -- No code available: the tech names the person they met. Counts as checked in, flagged for review.
 if coalesce(trim(p_person), '') = '' or coalesce(length(trim(p_reason)), 0) < 5 then
   raise exception 'Enter the name of the person you met and why no code was available.';
 end if;
 if p_checkout then
   update visits set checkout_at = greatest(t, arrived_at), checkout_method = p_method where id = v.id;
 else
   update visits set checkin_at = coalesce(checkin_at, greatest(t, arrived_at)), checkin_method = p_method, checkin_verified = false,
     checkin_person = trim(p_person), checkin_reason = trim(p_reason) where id = v.id;
 end if;
 perform _raise_flag(w.id, 'checkin_unverified', format('%s not verified: met %s — %s', what, trim(p_person), trim(p_reason)), true, true);
 perform _notify_customer(w.id, 'checkin', format('%s for call #%s could NOT be verified (technician says they met %s). Work continues; the contractor will review.',
   what, w.number, trim(p_person)));
 return jsonb_build_object('ok', true, 'verified', false);
end $$;
