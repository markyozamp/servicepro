-- Fair use: texts (1 credit) and automated phone calls (2 credits) per plan year, pooled across the company.
-- Allowance = locations x 600 + any packs bought this plan year. A pack = 1/12 of the yearly allowance, $10 per location.
-- Phone notifications and email are unlimited and never counted. Emergencies are never stopped.

alter table platform_settings
  add column if not exists fair_use_credits_per_location int not null default 600,
  add column if not exists fair_use_pack_price_per_location numeric(10,2) not null default 10;

create table if not exists usage_events (
  id            bigserial primary key,
  customer_id   uuid not null references customers(id),
  site_id       uuid references sites(id),
  work_order_id uuid references work_orders(id),
  kind          text not null check (kind in ('text', 'voice')),
  credits       int not null check (credits > 0),
  emergency     boolean not null default false,
  at            timestamptz not null default now()
);
create index if not exists usage_events_customer_at on usage_events (customer_id, at);
alter table usage_events enable row level security;

create table if not exists usage_topups (
  id          bigserial primary key,
  customer_id uuid not null references customers(id),
  packs       int not null check (packs > 0),
  credits     int not null check (credits > 0),
  amount      numeric(10,2) not null default 0,
  bought_at   timestamptz not null default now(),
  bought_by   uuid references profiles(id),
  note        text
);
alter table usage_topups enable row level security;

-- Plan year starts on the anniversary of the account (renewal date).
create or replace function _plan_year_start(p_customer uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  select c.created_at + make_interval(years => greatest(0, extract(year from age(now(), c.created_at))::int))
  from customers c where c.id = p_customer
$$;

-- Used by the text/phone sender when those go live.
create or replace function _record_usage(p_customer uuid, p_site uuid, p_wo uuid, p_kind text, p_emergency boolean default false) returns void
language sql security definer set search_path = public as $$
  insert into usage_events (customer_id, site_id, work_order_id, kind, credits, emergency)
  values (p_customer, p_site, p_wo, p_kind, case when p_kind = 'voice' then 2 else 1 end, coalesce(p_emergency, false))
$$;

create or replace function fair_use() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  m profiles := me(); cust uuid := m.customer_id; y0 timestamptz; y1 timestamptz; nsites int; per int; price numeric;
  base int; extra int; used int; months jsonb; elapsed numeric; projected int; pack int; short int; packs int;
begin
  if cust is null then raise exception 'Only a store account has a plan.'; end if;
  y0 := _plan_year_start(cust); y1 := y0 + interval '1 year';
  select count(*) into nsites from sites where customer_id = cust;
  select fair_use_credits_per_location, fair_use_pack_price_per_location into per, price from platform_settings limit 1;
  per := coalesce(per, 600); price := coalesce(price, 10);
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
  pack := greatest(1, round(base / 12.0)::int);
  short := greatest(0, projected - (base + extra));
  packs := ceil(short::numeric / pack);
  return jsonb_build_object(
    'year_start', y0::date, 'renews', y1::date, 'locations', nsites, 'per_location', per,
    'allowance', base + extra, 'base', base, 'topped_up', extra, 'used', used, 'remaining', greatest(0, base + extra - used),
    'pct', case when base + extra > 0 then round(100.0 * used / (base + extra)) else 0 end,
    'pace_per_month', round((base + extra) / 12.0), 'months', months,
    'projected', projected, 'pack_credits', pack, 'pack_price', greatest(nsites, 1) * price, 'suggested_packs', packs);
end $$;

revoke execute on function _plan_year_start(uuid), _record_usage(uuid, uuid, uuid, text, boolean) from public, anon, authenticated;
revoke execute on function fair_use() from public, anon;
grant execute on function fair_use() to authenticated;
revoke all on usage_events, usage_topups from anon, authenticated;
