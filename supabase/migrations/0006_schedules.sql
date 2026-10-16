-- =====================================================================
-- ServicePro v2 — scheduled jobs (Supabase pg_cron)
--   every 5 min : unanswered approvals move up the chain
--   hourly      : billing reminders / late-bill alerts / missed response times
--   daily 5 am  : create upcoming PM work orders, overdue PM alerts
--   monthly     : platform statements for the previous month
-- Skipped quietly where pg_cron is not installed (local tests).
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('servicepro-escalate', '*/5 * * * *', 'select public.escalate_stale_approvals()');
    perform cron.schedule('servicepro-billing',  '7 * * * *',   'select public.billing_clock()');
    perform cron.schedule('servicepro-pm',       '0 10 * * *',  'select public.pm_generate()');   -- 10:00 UTC ≈ 5 am Central
    perform cron.schedule('servicepro-monthly',  '0 12 1 * *',  $c$select public.monthly_billing_run((date_trunc('month', now()) - interval '1 month')::date)$c$);
  end if;
end $$;
