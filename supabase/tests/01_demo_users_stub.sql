-- Local test only: the demo logins (Supabase creates these through its auth system)
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','office@arcticair.demo'),
 ('00000000-0000-0000-0000-0000000000a2','dispatch@arcticair.demo'),
 ('00000000-0000-0000-0000-0000000000a3','tech@arcticair.demo'),
 ('00000000-0000-0000-0000-0000000000a4','luis@arcticair.demo'),
 ('00000000-0000-0000-0000-0000000000c1','store@northside.demo'),
 ('00000000-0000-0000-0000-0000000000c2','maint@northside.demo'),
 ('00000000-0000-0000-0000-0000000000c3','director@northside.demo'),
 ('00000000-0000-0000-0000-0000000000d1','homeowner@jensen.demo'),
 ('00000000-0000-0000-0000-0000000000b3','tech@othercontractor.demo'),
 ('00000000-0000-0000-0000-0000000000e1','pm@redriverpm.demo'),
 ('00000000-0000-0000-0000-0000000000e2','maint@redriverpm.demo');
