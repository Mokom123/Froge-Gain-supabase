-- Phase 15: X follow tasks, login streaks, daily reward. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run more than once.

-- 1. X "follow" tasks.
alter table public.tasks drop constraint if exists tasks_platform_kind_check;
alter table public.tasks add constraint tasks_platform_kind_check check (
  (platform = 'telegram' and kind = 'join') or
  (platform = 'x' and kind in ('like', 'repost', 'quote', 'comment', 'follow')) or
  (platform = 'tiktok' and kind in ('like', 'comment', 'share', 'follow')) or
  (platform = 'youtube' and kind in ('like', 'comment', 'subscribe', 'share')) or
  (platform = 'facebook' and kind in ('like', 'comment', 'share', 'follow'))
);
insert into public.app_settings (key, value) values ('points_x_follow', 10) on conflict (key) do nothing;

-- 2. Login streak (counts the days a person opened the app) and daily reward progress.
alter table public.profiles add column if not exists streak int not null default 0;
alter table public.profiles add column if not exists best_streak int not null default 0;
alter table public.profiles add column if not exists last_seen_date date;
alter table public.profiles add column if not exists daily_streak int not null default 0;
alter table public.profiles add column if not exists last_claim_date date;

-- Days change at midnight UTC.
create or replace function public.today_utc() returns date
language sql stable as $$ select (now() at time zone 'utc')::date $$;

-- Called every time the app opens with someone signed in. Registers today once.
create or replace function public.register_visit() returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); p public.profiles; t date := public.today_utc(); s int;
begin
  if uid is null then return json_build_object('streak', 0, 'best', 0); end if;
  select * into p from public.profiles where id = uid for update;
  if not found then return json_build_object('streak', 0, 'best', 0); end if;
  if p.last_seen_date = t then
    s := p.streak;
  else
    s := case when p.last_seen_date = t - 1 then p.streak + 1 else 1 end;
    update public.profiles set streak = s, best_streak = greatest(best_streak, s), last_seen_date = t where id = uid;
  end if;
  return json_build_object('streak', s, 'best', greatest(p.best_streak, s));
end $$;

-- 3. Daily reward: 1, 2, 3, 5, 8, 11, 15 TPoints, then 15 each day. Missing a day starts again at 1.
create or replace function public.daily_amounts() returns int[]
language sql immutable as $$ select array[1, 2, 3, 5, 8, 11, 15] $$;

create or replace function public.daily_status() returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); p public.profiles; t date := public.today_utc();
        nxt int; claimed boolean; run int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into p from public.profiles where id = uid;
  claimed := p.last_claim_date = t;
  run := case when p.last_claim_date >= t - 1 then p.daily_streak else 0 end; -- days in a row, still alive
  nxt := case when claimed then p.daily_streak else run + 1 end; -- the day number shown as "Today"
  return json_build_object(
    'day', nxt, 'claimed', claimed, 'streak', run,
    'amounts', public.daily_amounts(),
    'reward', (public.daily_amounts())[least(nxt, 7)]);
end $$;

create or replace function public.claim_daily() returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); p public.profiles; t date := public.today_utc(); n int; amt int;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  select * into p from public.profiles where id = uid for update;
  if p.last_claim_date = t then raise exception 'You already claimed today. Come back tomorrow.'; end if;
  n := case when p.last_claim_date = t - 1 then p.daily_streak + 1 else 1 end;
  amt := (public.daily_amounts())[least(n, 7)];
  insert into public.rewards (user_id, task_id, amount, status)
    values (uid, 'daily-' || t::text, amt, 'claimable');
  update public.profiles set daily_streak = n, last_claim_date = t where id = uid;
  return json_build_object('day', n, 'reward', amt);
end $$;

-- 4. Leaderboard shows the streak instead of time on the platform. A streak counts while the person
--    opened the app today or yesterday.
drop function if exists public.leaderboard();
create or replace function public.leaderboard()
returns table (id uuid, username text, display_name text, avatar_url text, created_at timestamptz, points bigint, badge boolean, streak int)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.created_at,
         coalesce((select sum(r.amount) from public.rewards r where r.user_id = p.id and r.status <> 'cancelled'), 0)::bigint as points,
         p.badge,
         (case when p.last_seen_date >= public.today_utc() - 1 then p.streak else 0 end)
  from public.profiles p
  where p.approved
  order by points desc, p.created_at asc
  limit 100
$$;

-- 5. Public profile also carries the streak.
create or replace function public.public_profile(p_user uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select p.id, p.username, p.display_name, p.bio, p.location, p.avatar_url, p.banner_url, p.badge,
         (case when p.last_seen_date >= public.today_utc() - 1 then p.streak else 0 end) as streak
    into r from public.profiles p
   where p.id = p_user and (p.approved or p.id = auth.uid());
  if not found then raise exception 'Profile not found'; end if;
  return json_build_object(
    'id', r.id, 'username', r.username, 'display_name', r.display_name, 'bio', r.bio,
    'location', r.location, 'avatar_url', r.avatar_url, 'banner_url', r.banner_url, 'badge', r.badge,
    'streak', r.streak,
    'followers', (select count(*) from public.follows where followed_id = p_user),
    'following', (select count(*) from public.follows where follower_id = p_user),
    'is_following', exists (select 1 from public.follows where follower_id = auth.uid() and followed_id = p_user),
    'is_me', p_user = auth.uid());
end $$;

revoke execute on function public.register_visit(), public.daily_status(), public.claim_daily(),
  public.leaderboard(), public.public_profile(uuid) from public, anon;
grant execute on function public.register_visit(), public.daily_status(), public.claim_daily(),
  public.leaderboard(), public.public_profile(uuid) to authenticated;
