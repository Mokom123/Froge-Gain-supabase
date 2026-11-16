-- Phase 18b: delete statuses completely after 24 hours (the file AND the row; nothing is kept).
-- Run in Supabase SQL Editor after phase18_update.sql. Then deploy the status-cleanup function (JWT OFF)
-- and run phase18c_schedule.sql.
create or replace function public.status_expired() returns table (id bigint, media_url text)
language sql stable security definer set search_path = public as $$
  select s.id, s.media_url from public.statuses s where s.expires_at <= now() order by s.id limit 200
$$;
create or replace function public.status_purge(p_ids bigint[]) returns void
language sql security definer set search_path = public as $$
  delete from public.statuses where id = any(p_ids) and expires_at <= now()
$$;
revoke execute on function public.status_expired(), public.status_purge(bigint[]) from public, anon, authenticated;
grant execute on function public.status_expired(), public.status_purge(bigint[]) to service_role;
