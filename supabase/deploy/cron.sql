-- Run ONCE in the Supabase SQL editor after deploying the Edge Functions (not a migration: it contains
-- project-specific values). Replace <PROJECT_REF> and store the worker secret in Vault first:
--   select vault.create_secret('<same value as WORKER_SECRET>', 'worker_secret');
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.schedule('notify-worker', '* * * * *', $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/notify-worker',
    headers := jsonb_build_object('x-worker-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'worker_secret'),
                                  'content-type', 'application/json'),
    body := '{}'::jsonb, timeout_milliseconds := 55000)
$$);
-- Monitoring: notifications waiting more than 2 minutes
--   select * from public.notification_health;
