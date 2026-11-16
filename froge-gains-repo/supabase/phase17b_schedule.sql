-- Phase 17b: run the chat cleanup every night at 03:00 UTC.
-- BEFORE running: turn on the "Cron" and "pg_net" integrations (Integrations page), then replace
-- YOUR_PROJECT_REF and YOUR_PUSH_SECRET (the SAME values you used in phase13b_update.sql).
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

select cron.schedule(
  'chat-cleanup',
  '0 3 * * *',
  $$ select net.http_post(
       url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/chat-cleanup',
       headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', 'YOUR_PUSH_SECRET'),
       body := '{}'::jsonb) $$
);
