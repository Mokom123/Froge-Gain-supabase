-- Phase 13b: sends a phone notification whenever a notification is created.
-- BEFORE running: replace YOUR_PROJECT_REF (the part of your Supabase URL before .supabase.co)
-- and YOUR_PUSH_SECRET (any long random text, the SAME text you save as the PUSH_SECRET secret).
create extension if not exists pg_net with schema extensions;

create or replace function public.push_on_notification() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', 'YOUR_PUSH_SECRET'),
    body := jsonb_build_object('record', to_jsonb(new))
  );
  return new;
exception when others then
  return new; -- a push problem must never block the notification itself
end $$;

drop trigger if exists on_notification_push on public.notifications;
create trigger on_notification_push after insert on public.notifications
  for each row execute function public.push_on_notification();
