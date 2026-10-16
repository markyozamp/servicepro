-- =====================================================================
-- ServicePro v2 — platform catalog (starting values; Mark edits these
-- from the admin screen). Amounts are what the store AUTHORIZES for
-- diagnosis, not a price contractors must charge.
-- =====================================================================
insert into trades (id, code, name) values
 (1,'refrigeration','Refrigeration'), (2,'hvac','Heating & air'), (3,'plumbing','Plumbing'),
 (4,'electrical','Electrical'), (5,'kitchen','Kitchen equipment'), (6,'general','General maintenance')
on conflict do nothing;

insert into equipment_types (trade_id, code, name) values
 (1,'rack','Refrigeration rack'), (1,'condenser','Condensing unit'), (1,'evaporator','Evaporator / coil'),
 (1,'walk_in_cooler','Walk-in cooler'), (1,'walk_in_freezer','Walk-in freezer'), (1,'display_case','Display case (remote)'),
 (1,'self_contained','Self-contained cooler / freezer'), (1,'reach_in','Reach-in'), (1,'make_table','Prep / make table'),
 (1,'ice_machine','Ice machine'),
 (2,'rtu','Rooftop unit (RTU)'), (2,'furnace','Furnace'), (2,'split_system','Split system A/C'), (2,'heat_pump','Heat pump'),
 (2,'boiler','Boiler'), (2,'mini_split','Ductless mini-split'),
 (3,'water_heater','Water heater'), (3,'plumbing_fixture','Plumbing fixture'), (3,'sump_pump','Sump pump'), (3,'drain','Drain / sewer line'),
 (4,'electrical_panel','Electrical panel'), (4,'lighting','Lighting'),
 (5,'exhaust_hood','Exhaust hood'), (5,'cooking','Cooking equipment'),
 (6,'other','Other')
on conflict do nothing;

insert into issue_types (code, name, trade_id, equipment_type_code, diagnosis_amount, priority, for_commercial, for_residential, sort) values
 ('wi_freezer_down',     'Walk-in freezer down / warm',                   1, 'walk_in_freezer', 250, 1, true,  false, 10),
 ('wi_cooler_down',      'Walk-in cooler down / warm',                    1, 'walk_in_cooler',  250, 1, true,  false, 20),
 ('case_warm',           'Display case warm',                             1, 'display_case',    200, 1, true,  false, 30),
 ('rack_alarm',          'Refrigeration rack alarm',                      1, 'rack',            250, 1, true,  false, 40),
 ('self_contained_down', 'Self-contained 2-door cooler / freezer down',   1, 'self_contained',  125, 2, true,  false, 50),
 ('ice_machine',         'Ice machine not making ice',                    1, 'ice_machine',     150, 2, true,  false, 60),
 ('no_heat',             'No heat',                                       2, 'furnace',         175, 1, true,  true,  70),
 ('no_cooling',          'No cooling (A/C)',                              2, 'rtu',             175, 2, true,  true,  80),
 ('water_leak',          'Water leak',                                    3, 'plumbing_fixture',150, 1, true,  true,  90),
 ('no_hot_water',        'No hot water',                                  3, 'water_heater',    150, 2, true,  true, 100),
 ('drain_backup',        'Drain clogged / backing up',                    3, 'drain',           150, 2, true,  true, 110),
 ('power_out',           'Power out to equipment / circuit',              4, 'electrical_panel',150, 1, true,  true, 120),
 ('hood_exhaust',        'Exhaust hood not working',                      5, 'exhaust_hood',    150, 2, true,  false,130),
 ('other',               'Other problem',                                 6, 'other',           125, 2, true,  true, 999)
on conflict do nothing;

-- Cost regions (starting point: a few high-cost metros; everywhere else 0%)
insert into cost_regions (name, adjust_pct) values
 ('Los Angeles metro', 40), ('San Francisco Bay Area', 45), ('New York metro', 45),
 ('Seattle metro', 20), ('Chicago metro', 15), ('Standard', 0)
on conflict do nothing;
insert into region_zip3 (zip3, region_id)
select z, (select id from cost_regions where name = r) from (values
  ('900','Los Angeles metro'),('901','Los Angeles metro'),('902','Los Angeles metro'),('903','Los Angeles metro'),
  ('904','Los Angeles metro'),('905','Los Angeles metro'),('906','Los Angeles metro'),('907','Los Angeles metro'),
  ('908','Los Angeles metro'),('910','Los Angeles metro'),('911','Los Angeles metro'),('912','Los Angeles metro'),
  ('913','Los Angeles metro'),('914','Los Angeles metro'),('915','Los Angeles metro'),('916','Los Angeles metro'),
  ('917','Los Angeles metro'),('918','Los Angeles metro'),
  ('940','San Francisco Bay Area'),('941','San Francisco Bay Area'),('943','San Francisco Bay Area'),('944','San Francisco Bay Area'),
  ('945','San Francisco Bay Area'),('946','San Francisco Bay Area'),('947','San Francisco Bay Area'),('948','San Francisco Bay Area'),
  ('949','San Francisco Bay Area'),('950','San Francisco Bay Area'),('951','San Francisco Bay Area'),
  ('100','New York metro'),('101','New York metro'),('102','New York metro'),('103','New York metro'),('104','New York metro'),
  ('110','New York metro'),('111','New York metro'),('112','New York metro'),('113','New York metro'),('114','New York metro'),
  ('070','New York metro'),('071','New York metro'),('072','New York metro'),('073','New York metro'),
  ('980','Seattle metro'),('981','Seattle metro'),
  ('600','Chicago metro'),('601','Chicago metro'),('606','Chicago metro'),('607','Chicago metro'),('608','Chicago metro')) x(z, r)
on conflict do nothing;

insert into holidays (day, name) values
 ('2026-11-26','Thanksgiving'), ('2026-12-25','Christmas Day'), ('2027-01-01','New Year''s Day'),
 ('2027-05-31','Memorial Day'), ('2027-07-05','Independence Day (observed)'), ('2027-09-06','Labor Day'),
 ('2027-11-25','Thanksgiving'), ('2027-12-24','Christmas Day (observed)')
on conflict do nothing;
