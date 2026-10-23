-- Neutral wording in alerts and messages: "the customer", "the person on site", "location" instead of "store".
-- Rewrites the live function bodies in place, so only the message text changes.
do $$
declare
  f record; src text; out_ text;
  pairs text[][] := array[
    ['Store disputed a bill', 'Customer disputed a bill'],
    ['— the store has not confirmed it yet.', '— the customer has not confirmed it yet.'],
    ['mi from the store (inside your', 'mi from the location (inside your'],
    [' Store rule: time not verified', ' Customer rule: time not verified'],
    ['The store has been told.', 'The customer has been told.'],
    ['did your store request it?', 'did you request it?'],
    ['— the store has not given the check-in code.', '— no one on site has given the check-in code yet.'],
    ['on site for the store''''s check-in code', 'on site for the check-in code'],
    ['Check in with the store person (enter their code).', 'Check in with the person on site (enter their code).'],
    ['Check out with the store person before leaving.', 'Check out with the person on site before leaving.'],
    ['checked in with the store', 'checked in on site'],
    ['Only a store account has a plan.', 'Only a customer account has a plan.'],
    ['reason the store will see.', 'reason the customer will see.'],
    ['This store has not set a reporting PIN yet.', 'This location has not set a reporting PIN yet.'],
    ['Wrong store PIN', 'Wrong PIN'],
    ['Ask the store to change it.', 'Ask the customer to change it.'],
    ['Your store opened this call', 'You opened this call'],
    ['(store)', '(customer)'],
    ['The store says you are at', 'The customer says you are at'],
    ['the store recorded', 'the customer recorded'],
    ['schedule the trip with the store and', 'schedule the trip with the customer and'],
    ['The store already approved this invoice.', 'The customer already approved this invoice.'],
    ['This store has no backup code set.', 'This location has no backup code set.'],
    ['check it with the store person', 'check it with the person on site'],
    ['The store and your office have been told.', 'The customer and your office have been told.'],
    ['with the store person, or use the store', 'with the person on site, or use the location'],
    [' (store backup code used)', ' (backup code used)'],
    ['Check in with the store first (their code)', 'Check in on site first (their code)'],
    ['(the store requires it here)', '(the customer requires it here)']
  ];
  i int;
begin
  for f in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
             and p.proname in ('_contractor_site_reasons','_create_call','_invoice_check','_invoice_rules','accept_watch','checkin_watch',
               'completion_check','demo_tech_enters_code','fair_use','mark_warranty_claim','qr_report','save_pm_plan','store_confirm_call',
               'store_tech_here','store_unexpected_visitor','store_visitor_log','submit_invoice','tech_checkin','tech_leave','trip_watch')
  loop
    src := pg_get_functiondef(f.oid); out_ := src;
    for i in 1 .. array_length(pairs, 1) loop
      out_ := replace(out_, pairs[i][1], pairs[i][2]);
    end loop;
    if out_ <> src then execute out_; end if;
  end loop;
end $$;
