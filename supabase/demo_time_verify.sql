-- ServicePro demo: Time Verify. Northside Grocers uses Prairie Plumbing (demo) on Time Verify for plumbing
-- and electrical; Arctic Air stays on the full product for refrigeration.
-- Logins (demo password): pete@prairieplumbing.demo (owner, also goes on calls), tony@prairieplumbing.demo (tech).
-- Run after seed.sql / demo_calls.sql. Safe to run once.

insert into contractors (id, name, phone, email) values
 ('10000000-0000-0000-0000-000000000005', 'Prairie Plumbing (demo)', '701-555-0100', 'pete@prairieplumbing.demo')
on conflict (id) do nothing;
insert into customer_contractors (contractor_id, customer_id, is_primary, mode, pays_travel)
values ('10000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000001', false, 'verify', 'yes')
on conflict (contractor_id, customer_id) do update set mode = 'verify';
insert into trade_contractors (customer_id, site_id, trade_id, contractor_id) values
 ('20000000-0000-0000-0000-000000000001', null, 3, '10000000-0000-0000-0000-000000000005'),
 ('20000000-0000-0000-0000-000000000001', null, 4, '10000000-0000-0000-0000-000000000005')
on conflict do nothing;

-- Logins with fixed ids (the same way a sign-in link creates them)
do $$
declare r record;
begin
  for r in select * from (values ('00000000-0000-0000-0000-0000000000f1'::uuid, 'pete@prairieplumbing.demo', 'Pete Larsen'),
                                 ('00000000-0000-0000-0000-0000000000f2'::uuid, 'tony@prairieplumbing.demo', 'Tony Berg')) x(id, email, name) loop
    if not exists (select 1 from auth.users where id = r.id) then
      if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = 'encrypted_password') then
        execute $q$insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, confirmation_token,
            recovery_token, email_change_token_new, email_change, email_change_token_current, phone_change, phone_change_token,
            reauthentication_token, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
          values ('00000000-0000-0000-0000-000000000000', $1, 'authenticated', 'authenticated', $2, extensions.crypt('DemoService2026!', extensions.gen_salt('bf')),
            now(), '', '', '', '', '', '', '', '', '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', $3), now(), now())$q$
          using r.id, r.email, r.name;
        execute $q$insert into auth.identities (id, user_id, provider_id, provider, identity_data, created_at, updated_at, last_sign_in_at)
          values (gen_random_uuid(), $1, $1::text, 'email', jsonb_build_object('sub', $1::text, 'email', $2, 'email_verified', true), now(), now(), now())$q$
          using r.id, r.email;
      else
        insert into auth.users (id, email) values (r.id, r.email);
      end if;
    end if;
  end loop;
end $$;
insert into profiles (id, org_kind, contractor_id, full_name, title, email, phone, is_org_admin, can_dispatch, can_bill, is_technician) values
 ('00000000-0000-0000-0000-0000000000f1', 'contractor', '10000000-0000-0000-0000-000000000005', 'Pete Larsen', 'Owner', 'pete@prairieplumbing.demo', '701-555-0100', true, true, true, true),
 ('00000000-0000-0000-0000-0000000000f2', 'contractor', '10000000-0000-0000-0000-000000000005', 'Tony Berg', 'Plumber', 'tony@prairieplumbing.demo', '701-555-0101', false, false, false, true)
on conflict (id) do nothing;

-- Store PIN for the QR stickers at both demo stores: 2468
insert into site_report_pins (site_id, pin_hash) values
 ('30000000-0000-0000-0000-000000000001', extensions.crypt('2468', extensions.gen_salt('bf'))),
 ('30000000-0000-0000-0000-000000000002', extensions.crypt('2468', extensions.gen_salt('bf')))
on conflict (site_id) do nothing;

-- Three calls to show: one finished with an invoice to check, one waiting to be accepted, one the store must confirm.
do $$
declare w work_orders; v visits; c text;
begin
  -- 1) Finished: Maria opened it, Tony went, a parts run, invoice bills 1 hour more than verified
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', true);
  w := open_po_call('30000000-0000-0000-0000-000000000002', (select id from issue_types where code = 'drain_backup'),
                    'Floor drain by the deli backing up', 'NS-4460', 600);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f2', true);
  v := tech_claim_call(w.id);
  perform tech_arrive(v.id, null, 47.8936, -97.0632, 'geofence');
  select code into c from visit_codes where visit_id = v.id;
  perform tech_checkin(v.id, 'code', c);
  perform tech_parts_run(v.id, 'leave', null, null, null, 47.8936, -97.0632);
  perform tech_parts_run(v.id, 'at_supplier', null, 'Ferguson Plumbing Supply', null, 47.9005, -97.0580);
  perform tech_parts_run(v.id, 'back', null, null, null, 47.8936, -97.0632);
  perform tech_leave(v.id, 'completed', 'Snaked the line 40 ft, replaced the trap. Draining normally.');
  perform _allow_internal(true);
  update visits set assigned_at = now() - interval '27 hours', received_at = now() - interval '27 hours',
         started_at = now() - interval '27 hours', arrived_at = now() - interval '26 hours 30 minutes',
         checkin_at = now() - interval '26 hours 28 minutes', departed_at = now() - interval '24 hours 30 minutes',
         completed_at = now() - interval '24 hours 30 minutes' where id = v.id;
  update parts_runs set left_at = now() - interval '25 hours 40 minutes', at_supplier_at = now() - interval '25 hours 25 minutes',
         returned_at = now() - interval '25 hours' where visit_id = v.id;
  update work_orders set created_at = now() - interval '28 hours', accepted_at = now() - interval '27 hours',
         first_arrived_at = now() - interval '26 hours 30 minutes', completed_at = now() - interval '24 hours 30 minutes',
         invoice_due_at = now() + interval '6 days' where id = w.id;
  perform _end_internal();
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', true);
  perform submit_invoice(w.id, 'PP-1042', 685, 3.5);

  -- 2) Waiting for the plumber to accept
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', true);
  perform open_po_call('30000000-0000-0000-0000-000000000002', (select id from issue_types where code = 'no_hot_water'),
                       'No hot water at the hand sinks in the deli', null, 450);

  -- 3) The plumber took this one by phone; the store has to confirm it
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000f1', true);
  perform enter_phone_call('30000000-0000-0000-0000-000000000001', (select id from issue_types where code = 'water_leak'),
                           'Leak under the 3-compartment sink', 'Kyle (night stocker)', '701-555-0177');
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
