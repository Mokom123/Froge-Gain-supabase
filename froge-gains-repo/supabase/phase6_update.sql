-- Phase 6. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Run phase5_update.sql first. Safe to run more than once.

-- 1. More platforms: TikTok, YouTube and Facebook tasks.
do $$
declare c record;
begin
  for c in select conname from pg_constraint where conrelid = 'public.tasks'::regclass and contype = 'c' loop
    execute format('alter table public.tasks drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.tasks add constraint tasks_points_check check (points > 0);
alter table public.tasks add constraint tasks_platform_kind_check check (
  (platform = 'telegram' and kind = 'join') or
  (platform = 'x' and kind in ('like', 'repost', 'quote', 'comment')) or
  (platform = 'tiktok' and kind in ('like', 'comment', 'share', 'follow')) or
  (platform = 'youtube' and kind in ('like', 'comment', 'subscribe', 'share')) or
  (platform = 'facebook' and kind in ('like', 'comment', 'share', 'follow'))
);

-- TPoints per task type are now stored per platform and type. Old values are carried over.
insert into public.app_settings (key, value) values
  ('points_telegram_join', coalesce((select value from public.app_settings where key = 'points_join'), 10)),
  ('points_x_like', coalesce((select value from public.app_settings where key = 'points_like'), 3)),
  ('points_x_repost', coalesce((select value from public.app_settings where key = 'points_repost'), 8)),
  ('points_x_quote', coalesce((select value from public.app_settings where key = 'points_quote'), 15)),
  ('points_x_comment', coalesce((select value from public.app_settings where key = 'points_comment'), 20)),
  ('points_tiktok_like', 3), ('points_tiktok_comment', 15), ('points_tiktok_share', 8), ('points_tiktok_follow', 10),
  ('points_youtube_like', 3), ('points_youtube_comment', 15), ('points_youtube_subscribe', 10), ('points_youtube_share', 8),
  ('points_facebook_like', 3), ('points_facebook_comment', 15), ('points_facebook_share', 8), ('points_facebook_follow', 10),
  ('referral_points', 5), ('referral_daily_cap', 3)
on conflict (key) do nothing;

-- The new-task notification now names the platform and the type.
create or replace function public.notify_new_task() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.active then
    insert into public.notifications (kind, title, body, task_id)
    values (
      'task',
      'New task: ' || new.title,
      (case new.platform when 'x' then 'X' when 'tiktok' then 'TikTok' when 'youtube' then 'YouTube'
                         when 'facebook' then 'Facebook' else 'Telegram' end)
        || ': ' ||
      (case new.kind when 'join' then 'join the group' when 'like' then 'like' when 'repost' then 'repost'
                     when 'quote' then 'quote' when 'comment' then 'comment' when 'share' then 'share'
                     when 'subscribe' then 'subscribe' else 'follow' end)
        || ' · +' || new.points || ' TPoints',
      new.id);
  end if;
  return new;
end $$;

-- 2. Followers.
create table if not exists public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followed_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followed_id),
  check (follower_id <> followed_id)
);
alter table public.follows enable row level security;

create or replace function public.toggle_follow(p_user uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if p_user = uid then raise exception 'You cannot follow yourself'; end if;
  if exists (select 1 from public.follows where follower_id = uid and followed_id = p_user) then
    delete from public.follows where follower_id = uid and followed_id = p_user;
    return false;
  end if;
  insert into public.follows (follower_id, followed_id) values (uid, p_user);
  return true;
end $$;

create or replace function public.public_profile(p_user uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select p.id, p.username, p.display_name, p.bio, p.location, p.avatar_url, p.banner_url
    into r from public.profiles p
   where p.id = p_user and (p.approved or p.id = auth.uid());
  if not found then raise exception 'Profile not found'; end if;
  return json_build_object(
    'id', r.id, 'username', r.username, 'display_name', r.display_name, 'bio', r.bio,
    'location', r.location, 'avatar_url', r.avatar_url, 'banner_url', r.banner_url,
    'followers', (select count(*) from public.follows where followed_id = p_user),
    'following', (select count(*) from public.follows where follower_id = p_user),
    'is_following', exists (select 1 from public.follows where follower_id = auth.uid() and followed_id = p_user),
    'is_me', p_user = auth.uid());
end $$;

create or replace function public.list_follows(p_user uuid, p_kind text)
returns table (id uuid, username text, display_name text, avatar_url text, is_following boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url,
         exists (select 1 from public.follows f2 where f2.follower_id = auth.uid() and f2.followed_id = p.id)
  from public.follows f
  join public.profiles p on p.id = case when p_kind = 'followers' then f.follower_id else f.followed_id end
  where (case when p_kind = 'followers' then f.followed_id else f.follower_id end) = p_user
  order by f.created_at desc
  limit 200
$$;

create or replace function public.search_users(p_q text)
returns table (id uuid, username text, display_name text, avatar_url text)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url
  from public.profiles p
  where p.approved
    and (p.username ilike '%' || p_q || '%' or coalesce(p.display_name, '') ilike '%' || p_q || '%')
  order by p.username
  limit 20
$$;

-- The task page now links each person who completed it to their profile.
drop function if exists public.task_completers(text);
create function public.task_completers(p_task_id text)
returns table (user_id uuid, username text, display_name text, avatar_url text, completed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url, c.created_at
  from public.completions c
  join public.profiles p on p.id = c.user_id
  where c.task_id = p_task_id
  order by c.created_at desc
  limit 100
$$;

-- 3. Notifications for one person (for example a new follower).
alter table public.notifications add column if not exists user_id uuid references public.profiles(id) on delete cascade;
alter table public.notifications add column if not exists actor_id uuid references public.profiles(id) on delete cascade;
drop policy if exists "read notifications" on public.notifications;
create policy "read notifications" on public.notifications
  for select to authenticated using (user_id is null or user_id = auth.uid());

create or replace function public.notify_follow() returns trigger
language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  select coalesce(nullif(trim(display_name), ''), username) into nm from public.profiles where id = new.follower_id;
  if not exists (select 1 from public.notifications
                 where kind = 'follow' and user_id = new.followed_id and actor_id = new.follower_id
                   and created_at > now() - interval '1 day') then
    insert into public.notifications (kind, title, user_id, actor_id)
    values ('follow', nm || ' started following you', new.followed_id, new.follower_id);
  end if;
  return new;
end $$;
drop trigger if exists on_follow_created on public.follows;
create trigger on_follow_created after insert on public.follows
  for each row execute function public.notify_follow();

-- 4. Referrals. A new person enters the username of whoever invited them when they sign up.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inviter uuid;
begin
  select id into inviter from public.profiles
   where lower(username) = lower(coalesce(new.raw_user_meta_data->>'referral', ''));
  insert into public.profiles (id, username, referred_by)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)), inviter);
  return new;
end $$;

-- The inviter earns TPoints when the new person is approved (up to a daily limit).
create or replace function public.admin_set_approved(p_user uuid, p_approved boolean) returns void
language plpgsql security definer set search_path = public as $$
declare
  inviter uuid;
  was boolean;
  reward numeric := coalesce((select value from public.app_settings where key = 'referral_points'), 5);
  cap numeric := coalesce((select value from public.app_settings where key = 'referral_daily_cap'), 3);
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  select approved, referred_by into was, inviter from public.profiles where id = p_user;
  update public.profiles set approved = p_approved where id = p_user;
  if p_approved and not coalesce(was, false) and inviter is not null then
    if (select count(*) from public.rewards r
        where r.user_id = inviter and r.task_id like 'referral:%'
          and r.created_at >= date_trunc('day', now())) < cap then
      insert into public.rewards (user_id, task_id, amount, status)
      values (inviter, 'referral:' || p_user::text, reward, 'claimable')
      on conflict do nothing;
    end if;
  end if;
end $$;

create or replace function public.my_referrals() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  return json_build_object(
    'referees', (select count(*) from public.profiles where referred_by = auth.uid()),
    'bonus', coalesce((select sum(amount) from public.rewards
                       where user_id = auth.uid() and task_id like 'referral:%' and status <> 'cancelled'), 0),
    'today', (select count(*) from public.rewards
              where user_id = auth.uid() and task_id like 'referral:%' and created_at >= date_trunc('day', now())),
    'cap', coalesce((select value from public.app_settings where key = 'referral_daily_cap'), 3),
    'reward', coalesce((select value from public.app_settings where key = 'referral_points'), 5));
end $$;

-- 5. The admin summary.
create or replace function public.admin_overview() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return json_build_object(
    'users_total', (select count(*) from public.profiles),
    'users_approved', (select count(*) from public.profiles where approved),
    'users_pending', (select count(*) from public.profiles where not approved),
    'users_suspended', (select count(*) from public.profiles where suspended_until > now()),
    'tasks_total', (select count(*) from public.tasks),
    'tasks_active', (select count(*) from public.tasks where active),
    'tasks_by_platform', (select coalesce(json_object_agg(platform, n), '{}'::json)
                          from (select platform, count(*) as n from public.tasks group by platform) s),
    'businesses', (select count(*) from public.businesses),
    'ads', (select count(*) from public.ads),
    'tickets_open', (select count(*) from public.support_tickets where status = 'open'));
end $$;

revoke execute on function public.toggle_follow(uuid), public.public_profile(uuid),
  public.list_follows(uuid, text), public.search_users(text), public.task_completers(text),
  public.my_referrals(), public.admin_overview(), public.admin_set_approved(uuid, boolean)
  from public, anon;
grant execute on function public.toggle_follow(uuid), public.public_profile(uuid),
  public.list_follows(uuid, text), public.search_users(text), public.task_completers(text),
  public.my_referrals(), public.admin_overview(), public.admin_set_approved(uuid, boolean)
  to authenticated;
