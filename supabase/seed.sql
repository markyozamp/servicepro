-- Demo data: one refrigeration contractor, one grocery customer, one store.
-- Used by the tests and for demos. Fixed ids make it easy to log in as each role.

insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','owner@arcticair.test'),
 ('00000000-0000-0000-0000-0000000000a2','dispatch@arcticair.test'),
 ('00000000-0000-0000-0000-0000000000a3','mike@arcticair.test'),
 ('00000000-0000-0000-0000-0000000000c1','manager@northside.test'),
 ('00000000-0000-0000-0000-0000000000b3','tech@othercontractor.test');

insert into contractors (id, name, labor_rate, min_labor_minutes, labor_increment_min, trip_charge, parts_markup_pct) values
 ('10000000-0000-0000-0000-000000000001','Arctic Air Mechanical', 125, 60, 15, 45, 35),
 ('10000000-0000-0000-0000-000000000002','Other Contractor LLC',   110, 60, 15, 0, 30);

insert into customers (id, name) values ('20000000-0000-0000-0000-000000000001','Northside Grocers');

insert into service_agreements (contractor_id, customer_id, qbo_customer_ref) values
 ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','QBO-58');

-- Store #114 (a Grand Forks-area coordinate)
insert into sites (id, customer_id, name, address, lat, lon, geofence_radius_ft) values
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Store #114',
  '1200 S Washington St, Grand Forks, ND', 47.9100, -97.0490, 300);

insert into profiles (id, role, full_name, contractor_id, customer_id) values
 ('00000000-0000-0000-0000-0000000000a1','contractor_admin','Dana Owner',      '10000000-0000-0000-0000-000000000001', null),
 ('00000000-0000-0000-0000-0000000000a2','dispatcher',      'Pat Dispatch',    '10000000-0000-0000-0000-000000000001', null),
 ('00000000-0000-0000-0000-0000000000a3','technician',      'Mike Tech',       '10000000-0000-0000-0000-000000000001', null),
 ('00000000-0000-0000-0000-0000000000c1','customer_admin',  'Sam Store Mgr',   null, '20000000-0000-0000-0000-000000000001'),
 ('00000000-0000-0000-0000-0000000000b3','technician',      'Rival Tech',      '10000000-0000-0000-0000-000000000002', null);

insert into parts (id, contractor_id, sku, name, category, unit_cost, unit_price) values
 ('40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','CFM-1/3-1075','Condenser fan motor 1/3HP 1075RPM','Motors',182.00,289.00),
 ('40000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','CAP-5-370',  'Run capacitor 5µF 370V',           'Electrical',9.50,24.00),
 ('40000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','BLD-20-4-27','Fan blade 20" 4-wing 27°',         'Blades',41.00,68.00),
 ('40000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','COIL-CLN-1', 'Coil cleaner (gal)',               'Chemicals',18.00,null);

insert into repair_types (id, contractor_id, name, summary_template, applies_to, parts_required,
                          expected_cost_min, expected_cost_max, expected_labor_min, expected_labor_max) values
 ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Replace condenser fan motor',
  'Found condenser fan motor failed on {equipment} ({location}). Replaced motor and run capacitor, verified rotation, amp draw and head pressure.',
  '{condenser,rack}', true, 400, 750, 45, 120),
 ('50000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','Clean condenser coil',
  'Condenser coil on {equipment} ({location}) was dirty. Cleaned coil and verified operation.',
  '{condenser,rack,reach_in}', false, 150, 300, 30, 90);

insert into repair_type_parts (repair_type_id, part_id, quantity) values
 ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',1),
 ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002',1);

-- $5 per call, capped at $50/month for the contractor
insert into fee_plans (org_kind, org_id, per_call, monthly_cap) values
 ('contractor','10000000-0000-0000-0000-000000000001',5,50);
