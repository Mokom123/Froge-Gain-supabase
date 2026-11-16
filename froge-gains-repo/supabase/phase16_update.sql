-- Phase 16: link YouTube accounts and verify YouTube tasks automatically.
-- Run in Supabase: SQL Editor > New query > paste all > Run. Safe to run more than once.

-- The linked YouTube channel. The refresh token lets the server check tasks later, so only the
-- server can read this table. The app only sees the channel name through my_youtube().
create table if not exists public.youtube_links (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  channel_id text unique not null,
  channel_title text,
  refresh_token text not null,
  created_at timestamptz not null default now()
);
alter table public.youtube_links enable row level security;
revoke all on public.youtube_links from authenticated, anon;

-- Temporary data for one sign-in attempt.
create table if not exists public.yt_oauth_states (
  state text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.yt_oauth_states enable row level security;
revoke all on public.yt_oauth_states from authenticated, anon;

create or replace function public.my_youtube() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select json_build_object('linked', true, 'username', channel_title)
       from public.youtube_links where user_id = auth.uid()),
    json_build_object('linked', false, 'username', null))
$$;

create or replace function public.unlink_youtube() returns void
language sql security definer set search_path = public as $$
  delete from public.youtube_links where user_id = auth.uid()
$$;

revoke execute on function public.my_youtube(), public.unlink_youtube() from public, anon;
grant execute on function public.my_youtube(), public.unlink_youtube() to authenticated;

-- Only the server (after checking with YouTube) can pay out a verified task.
create or replace function public.claim_verified_task(p_user uuid, p_task text) returns int
language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  if not coalesce((select approved and (suspended_until is null or suspended_until <= now())
                   from public.profiles where id = p_user), false) then
    raise exception 'Your account is not active';
  end if;
  select * into t from public.tasks where id::text = p_task and active and platform = 'youtube';
  if not found then raise exception 'Task not available'; end if;
  insert into public.completions (user_id, task_id) values (p_user, p_task);
  insert into public.rewards (user_id, task_id, amount, status) values (p_user, p_task, t.points, 'claimable');
  return t.points;
exception when unique_violation then
  raise exception 'Task already completed';
end $$;
revoke execute on function public.claim_verified_task(uuid, text) from public, anon, authenticated;
grant execute on function public.claim_verified_task(uuid, text) to service_role;

-- The app can no longer claim Telegram or checkable YouTube tasks directly.
create or replace function public.claim_task(p_task_id text) returns int
language plpgsql security definer set search_path = public as $$
declare
  t public.tasks;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  select * into t from public.tasks where id::text = p_task_id and active;
  if not found then raise exception 'Task not available'; end if;
  if t.platform = 'telegram' then
    raise exception 'Telegram tasks are checked by the Froge bot. Link your Telegram account first.';
  end if;
  if t.platform = 'youtube' and t.kind in ('like', 'comment', 'subscribe') then
    raise exception 'YouTube tasks are checked automatically. Link your YouTube account first.';
  end if;
  insert into public.completions (user_id, task_id) values (uid, p_task_id);
  insert into public.rewards (user_id, task_id, amount, status) values (uid, p_task_id, t.points, 'claimable');
  return t.points;
exception when unique_violation then
  raise exception 'Task already completed';
end $$;
