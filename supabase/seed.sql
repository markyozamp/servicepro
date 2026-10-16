-- Demo data (NOT for production customers). Assumes these logins already exist in auth.users:
--  a1 office@arcticair.demo   a2 dispatch@arcticair.demo   a3 tech@arcticair.demo   a4 luis@arcticair.demo
--  c1 store@northside.demo    c2 maint@northside.demo      c3 director@northside.demo
--  b3 tech@othercontractor.demo   e1 pm@redriverpm.demo   e2 maint@redriverpm.demo
-- (The Jensen residence is a one-off homeowner with no login: the office opens her calls.)

insert into contractors (id, name, phone, labor_rate, after_hours_labor_rate, min_labor_minutes, labor_increment_min, trip_charge, parts_markup_pct, fees_waived_until) values
 ('10000000-0000-0000-0000-000000000001','Arctic Air Mechanical (demo)','701-555-0142', 125, 187.50, 60, 15, 45, 35, null),
 ('10000000-0000-0000-0000-000000000002','Other Contractor LLC (demo)', '701-555-0199', 110, 165,    60, 15, 0,  30, null);

insert into customers (id, name, kind, letter_escalation_at) values
 ('20000000-0000-0000-0000-000000000001','Northside Grocers (demo)','commercial', 3),
 ('20000000-0000-0000-0000-000000000002','Jensen residence (demo)','residential', 3);
update customers set phone = '701-555-0166' where id = '20000000-0000-0000-0000-000000000002';

insert into customer_contractors (contractor_id, customer_id, qbo_customer_ref) values
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','QBO-58'),
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002','QBO-77');

insert into sites (id, customer_id, name, address, zip, lat, lon, geofence_radius_ft, access_notes, require_checkin, timezone) values
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Store #114','1200 S Washington St, Grand Forks, ND','58201', 47.9100, -97.0490, 300,
  'Roof hatch behind dairy cooler; key at service desk', true, 'America/Chicago'),
 ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','Store #121','3051 32nd Ave S, Grand Forks, ND','58201', 47.8935, -97.0631, 300,
  null, false, 'America/Chicago'),
 ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000002','Jensen home','418 Belmont Rd, Grand Forks, ND','58201', 47.9045, -97.0402, 200,
  'Side door; dog is friendly', false, 'America/Chicago');

insert into profiles (id, org_kind, contractor_id, customer_id, full_name, title, email, phone,
                      is_org_admin, is_technician, can_dispatch, can_bill, hourly_cost,
                      can_open_calls, can_approve, approval_limit, can_manage_pm, can_see_billing, all_sites) values
 ('00000000-0000-0000-0000-0000000000a1','contractor','10000000-0000-0000-0000-000000000001',null,'Dana Owner','Owner','office@arcticair.demo',null,
   true,false,true,true,null, false,false,null,false,false,true),
 ('00000000-0000-0000-0000-0000000000a2','contractor','10000000-0000-0000-0000-000000000001',null,'Pat Dispatch','Dispatcher','dispatch@arcticair.demo',null,
   false,false,true,false,null, false,false,null,false,false,true),
 ('00000000-0000-0000-0000-0000000000a3','contractor','10000000-0000-0000-0000-000000000001',null,'Mike Tech','Service Technician','tech@arcticair.demo','701-555-0110',
   false,true,false,false,38, false,false,null,false,false,true),
 ('00000000-0000-0000-0000-0000000000a4','contractor','10000000-0000-0000-0000-000000000001',null,'Luis Ortega','Service Technician','luis@arcticair.demo','701-555-0111',
   false,true,false,false,34, false,false,null,false,false,true),
 ('00000000-0000-0000-0000-0000000000c1','customer',null,'20000000-0000-0000-0000-000000000001','Sam Store Manager','Store Manager, #114','store@northside.demo',null,
   false,false,false,false,null, true,true,500,false,false,false),
 ('00000000-0000-0000-0000-0000000000c2','customer',null,'20000000-0000-0000-0000-000000000001','Maria Lopez','Maintenance Manager','maint@northside.demo',null,
   false,false,false,false,null, true,true,2500,true,true,true),
 ('00000000-0000-0000-0000-0000000000c3','customer',null,'20000000-0000-0000-0000-000000000001','Doug Reed','Director of Operations','director@northside.demo',null,
   true,false,false,false,null, true,true,null,true,true,true),
 ('00000000-0000-0000-0000-0000000000b3','contractor','10000000-0000-0000-0000-000000000002',null,'Rival Tech','Technician','tech@othercontractor.demo',null,
   false,true,false,false,null, false,false,null,false,false,true);
insert into profile_sites values ('00000000-0000-0000-0000-0000000000c1','30000000-0000-0000-0000-000000000001');

-- Escalation: store manager ($500) → maintenance manager ($2,500) → director (no limit); 30 min to answer
insert into approval_chains (id, customer_id, name, all_sites, timeout_minutes, emergency_profile_id) values
 ('60000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','All stores', true, 30, '00000000-0000-0000-0000-0000000000c2');
insert into approval_chain_steps (chain_id, step_no, profile_id, backup_profile_id) values
 ('60000000-0000-0000-0000-000000000001',1,'00000000-0000-0000-0000-0000000000c1',null),
 ('60000000-0000-0000-0000-000000000001',2,'00000000-0000-0000-0000-0000000000c2','00000000-0000-0000-0000-0000000000c3'),
 ('60000000-0000-0000-0000-000000000001',3,'00000000-0000-0000-0000-0000000000c3',null);

insert into warranty_terms (id, contractor_id, name, labor_days, parts_days, sort) values
 ('70000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','90-day labor / 1-year parts', 90, 365, 10),
 ('70000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','90-day labor only', 90, 0, 20),
 ('70000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','1-year labor / 5-year compressor', 365, 1825, 30),
 ('70000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','6-month labor / 6-month parts', 180, 180, 40);

insert into parts (id, contractor_id, sku, name, category, unit_cost, unit_price) values
 ('40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','CFM-1/3-1075','Condenser fan motor 1/3HP 1075RPM','Motors',182.00,289.00),
 ('40000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','CAP-5-370','Run capacitor 5µF 370V','Electrical',9.50,24.00),
 ('40000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','BLD-20-4-27','Fan blade 20" 4-wing 27°','Blades',41.00,68.00),
 ('40000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','COIL-CLN-1','Coil cleaner (gal)','Chemicals',18.00,null),
 ('40000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000001','CONT-40A-2P','Contactor 40A 2-pole 24V coil','Electrical',22.00,58.00),
 ('40000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000001','DT-HTR-240','Defrost heater 240V','Defrost',64.00,139.00),
 ('40000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000001','FLT-20x25x2','Air filter 20x25x2','Filters',6.00,14.00),
 ('40000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000001','DT-TERM-50','Defrost termination thermostat','Defrost',29.00,74.00);

insert into repair_types (id, contractor_id, trade_id, name, summary_template, equipment_type_codes, parts_required, default_warranty_id,
                          expected_cost_min, expected_cost_max, expected_labor_min, expected_labor_max) values
 ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',1,'Replace condenser fan motor',
  'Found condenser fan motor failed on {equipment} ({location}). Replaced motor and run capacitor, verified rotation, amp draw and head pressure.',
  '{condenser,rack}', true, '70000000-0000-0000-0000-000000000001', 400, 750, 45, 120),
 ('50000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001',1,'Clean condenser coil',
  'Condenser coil on {equipment} ({location}) was dirty. Cleaned coil and verified operation.',
  '{condenser,rack,self_contained,reach_in}', false, '70000000-0000-0000-0000-000000000002', 150, 300, 30, 90),
 ('50000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001',1,'Replace contactor',
  'Contactor on {equipment} ({location}) had pitted contacts. Replaced contactor and verified operation.',
  null, true, '70000000-0000-0000-0000-000000000001', 200, 400, 30, 90),
 ('50000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001',1,'Replace defrost heater',
  'Defrost heater on {equipment} ({location}) open. Replaced heater, ran a defrost cycle and verified termination.',
  '{walk_in_freezer,evaporator,display_case}', true, '70000000-0000-0000-0000-000000000001', 300, 650, 60, 150);
insert into repair_type_parts (repair_type_id, part_id, quantity) values
 ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',1),
 ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002',1),
 ('50000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000004',1),
 ('50000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000005',1),
 ('50000000-0000-0000-0000-000000000004','40000000-0000-0000-0000-000000000006',1);

insert into equipment (id, customer_id, site_id, equipment_type_id, manufacturer, model, serial, refrigerant, location_description, identity_confirmed) values
 ('80000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',
  (select id from equipment_types where code = 'walk_in_freezer' and contractor_id is null),'Bohn','BHA0400','K19C23311','R-404A','Back room, walk-in freezer', true),
 ('80000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',
  (select id from equipment_types where code = 'condenser' and contractor_id is null),'Heatcraft','MOH050H2C','T21K04512','R-448A','Roof, condenser 3', true);

-- Store #114 maintenance agreement: PM + labor covered, 4-hour emergency response, $225 diagnosis
insert into agreements (id, contractor_id, customer_id, name, starts_on, ends_on, all_sites, coverage, fee_amount, fee_interval, next_fee_on,
                        labor_discount_pct, parts_discount_pct, diagnosis_amount, response_emergency_min, response_normal_min, status, accepted_at) values
 ('90000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
  'Store #114 refrigeration agreement', current_date - 60, current_date + 305, false, 'pm_labor', 450, 'monthly', current_date + 1,
  0, 10, 225, 240, 1440, 'active', now() - interval '60 days');
insert into agreement_sites values ('90000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001');

-- Quarterly refrigeration PM at #114 (under the agreement) and a flat-price PM at #121
insert into pm_plans (id, contractor_id, customer_id, site_id, agreement_id, trade_id, name, frequency_months, checklist, price, lead_days, next_due_on) values
 ('a0000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001',
  '90000000-0000-0000-0000-000000000001', 1, 'Quarterly refrigeration PM', 3,
  '[{"item":"Clean condenser coils","photo":true,"required":true},
    {"item":"Check walk-in freezer temperature","reading":"°F","required":true},
    {"item":"Check door gaskets and heaters","required":true},
    {"item":"Inspect evaporator drain lines","required":true}]', null, 14, current_date + 10),
 ('a0000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002',
  null, 2, 'Semi-annual HVAC PM', 6,
  '[{"item":"Replace air filters","photo":true,"required":true},{"item":"Check belts","required":true},{"item":"Supply air temperature","reading":"°F","required":true}]',
  189, 14, current_date - 3);
insert into pm_plan_parts values ('a0000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000007',4);

insert into wholesalers (id, name, invite_code, commission_pct) values
 ('b0000000-0000-0000-0000-000000000001','Prairie Wholesale Grocers (demo)','PRAIRIE', 15);
update customers set wholesaler_id = 'b0000000-0000-0000-0000-000000000001' where id = '20000000-0000-0000-0000-000000000001';

-- Property management company: an apartment building and an office building, each with its owner,
-- plus a duplex the company owns itself (no owner step).
insert into customers (id, name, kind, phone, letter_escalation_at) values
 ('20000000-0000-0000-0000-000000000003','Red River Property Management (demo)','property_manager','701-555-0300', 3);
insert into customer_contractors (contractor_id, customer_id, qbo_customer_ref) values
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003','QBO-91');
insert into property_owners (id, customer_id, name, phone, email, approval_above, response_hours, notes) values
 ('c0000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000003','Lakeview Holdings LLC (Tom Becker)','701-555-0311','tom@lakeview.demo', 750, 24, 'Management agreement: owner approves repairs over $750'),
 ('c0000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000003','Gateway Partners (Linda Ruiz)','701-555-0322','linda@gateway.demo', 1500, 48, null);
insert into sites (id, customer_id, name, address, zip, lat, lon, geofence_radius_ft, access_notes, require_checkin, timezone, property_type, owner_id) values
 ('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000003','Riverside Apartments','2200 River Rd, Grand Forks, ND','58201', 47.9200, -97.0300, 300,
  'Mechanical room off the north stairwell; super has keys', true, 'America/Chicago', 'residential', 'c0000000-0000-0000-0000-000000000001'),
 ('30000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000003','Gateway Office Center','400 Demers Ave, Grand Forks, ND','58201', 47.9250, -97.0330, 300,
  'Roof access by building engineer', false, 'America/Chicago', 'commercial', 'c0000000-0000-0000-0000-000000000002'),
 ('30000000-0000-0000-0000-000000000006','20000000-0000-0000-0000-000000000003','Maple St duplex','1510 Maple St, Grand Forks, ND','58201', 47.9150, -97.0450, 200,
  null, false, 'America/Chicago', 'residential', null);
insert into profiles (id, org_kind, contractor_id, customer_id, full_name, title, email, phone,
                      is_org_admin, is_technician, can_dispatch, can_bill, hourly_cost,
                      can_open_calls, can_approve, approval_limit, can_manage_pm, can_see_billing, all_sites) values
 ('00000000-0000-0000-0000-0000000000e1','customer',null,'20000000-0000-0000-0000-000000000003','Jordan Hale','Property Manager','pm@redriverpm.demo',null,
   true,false,false,false,null, true,true,2500,true,true,true),
 ('00000000-0000-0000-0000-0000000000e2','customer',null,'20000000-0000-0000-0000-000000000003','Chris Moe','Maintenance Coordinator','maint@redriverpm.demo',null,
   false,false,false,false,null, true,true,500,true,false,true);
insert into approval_chains (id, customer_id, name, all_sites, timeout_minutes, emergency_profile_id) values
 ('60000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000003','All properties', true, 60, '00000000-0000-0000-0000-0000000000e1');
insert into approval_chain_steps (chain_id, step_no, profile_id, backup_profile_id) values
 ('60000000-0000-0000-0000-000000000002',1,'00000000-0000-0000-0000-0000000000e2',null),
 ('60000000-0000-0000-0000-000000000002',2,'00000000-0000-0000-0000-0000000000e1',null);
