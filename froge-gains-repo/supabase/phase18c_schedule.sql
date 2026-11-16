-- Phase 18c: run the status cleanup every 15 minutes.
-- BEFORE running: replace YOUR_PROJECT_REF and YOUR_PUSH_SECRET (the SAME values used in phase17b_schedule.sql).
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

select cron.schedule(
  'status-cleanup',
  '*/15 * * * *',
  $$ select net.http_post(
       url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/status-cleanup',
       headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', 'YOUR_PUSH_SECRET'),
       body := '{}'::jsonb) $$
);
