-- ServicePro 0017 — Every minute the database asks the web app to send waiting alerts (phone push now; email once set up).
-- The web app checks the key (Vercel env OUTBOX_KEY = app_secrets 'outbox'). Skipped where pg_net/pg_cron are missing (local tests).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') and exists (select 1 from pg_extension where extname = 'pg_cron') then
    create extension if not exists pg_net;
    perform cron.schedule('servicepro-outbox', '* * * * *', $c$select net.http_post(url := 'https://servicepro-two.vercel.app/api/outbox', headers := jsonb_build_object('x-outbox-key', (select value from public.app_secrets where name = 'outbox'), 'content-type', 'application/json'), body := '{}'::jsonb, timeout_milliseconds := 20000)$c$);
  end if;
end $$;
