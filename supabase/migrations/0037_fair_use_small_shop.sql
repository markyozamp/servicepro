-- Fair use sized for the smallest shop (a take-out pizza place): 150 credits per location per year.
-- Busier stores top up with flat packs: 100 credits for $10, good to the end of the plan year.
alter table platform_settings
  add column if not exists fair_use_pack_credits int not null default 100,
  add column if not exists fair_use_pack_price numeric(10,2) not null default 10;
alter table platform_settings alter column fair_use_credits_per_location set default 150;
update platform_settings set fair_use_credits_per_location = 150 where id;

create or replace function fair_use() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m profiles := me(); cust uuid := m.customer_id; y0 timestamptz; y1 timestamptz; nsites int; per int; price numeric;
  base int; extra int; pk int; pkp numeric; used int; months jsonb; elapsed numeric; projected int; pack int; short int; packs int;
begin
  if cust is null then raise exception 'Only a store account has a plan.'; end if;
  y0 := _plan_year_start(cust); y1 := y0 + interval '1 year';
  select count(*) into nsites from sites where customer_id = cust;
  select fair_use_credits_per_location, fair_use_pack_price_per_location into per, price from platform_settings limit 1;
  select fair_use_pack_credits, fair_use_pack_price into pk, pkp from platform_settings limit 1;
  per := coalesce(per, 150); pk := coalesce(pk, 100); pkp := coalesce(pkp, 10);
  base := greatest(nsites, 1) * per;
  select coalesce(sum(credits), 0) into extra from usage_topups where customer_id = cust and bought_at >= y0;
  select coalesce(sum(credits), 0) into used from usage_events where customer_id = cust and at >= y0;
  select jsonb_agg(jsonb_build_object('month', to_char(ms, 'Mon'), 'start', ms::date,
           'texts', (select coalesce(sum(credits), 0) from usage_events e where e.customer_id = cust and e.kind = 'text' and e.at >= ms and e.at < ms + interval '1 month'),
           'calls', (select coalesce(sum(credits), 0) from usage_events e where e.customer_id = cust and e.kind = 'voice' and e.at >= ms and e.at < ms + interval '1 month'),
           'future', ms > now()) order by ms)
    into months from generate_series(y0, y0 + interval '11 months', interval '1 month') ms;
  elapsed := greatest(1, extract(epoch from (now() - y0)) / (365.25 * 86400 / 12));   -- months, at least 1 so early weeks don't swing wildly
  projected := round(used / elapsed * 12);
  pack := pk;
  short := greatest(0, projected - (base + extra));
  packs := ceil(short::numeric / pack);
  return jsonb_build_object(
    'year_start', y0::date, 'renews', y1::date, 'locations', nsites, 'per_location', per,
    'allowance', base + extra, 'base', base, 'topped_up', extra, 'used', used, 'remaining', greatest(0, base + extra - used),
    'pct', case when base + extra > 0 then round(100.0 * used / (base + extra)) else 0 end,
    'pace_per_month', round((base + extra) / 12.0), 'months', months,
    'projected', projected, 'pack_credits', pack, 'pack_price', pkp, 'suggested_packs', packs);
end $$;
