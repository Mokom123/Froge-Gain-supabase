-- Phase 21: the streak now follows the daily claims. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run more than once.
--  * The streak counts the days in a row someone claimed their daily reward. It keeps counting past day 7
--    (day 8, 9, 10 ...); only the reward amount stays at 15 after day 7. Missing a day starts again at 1.
--  * Days now change at midnight in Cameroon time (Africa/Douala) instead of midnight UTC, so nobody is
--    caught out by a day that ends at 1 AM for them.

create or replace function public.today_utc() returns date
language sql stable as $$ select (now() at time zone 'Africa/Douala')::date $$;

-- The live streak: still counting if the last claim was today or yesterday.
create or replace function public.my_streak() returns int
language sql stable security definer set search_path = public as $$
  select coalesce((select case when p.last_claim_date >= public.today_utc() - 1 then p.daily_streak else 0 end
                   from public.profiles p where p.id = auth.uid()), 0)
$$;
grant execute on function public.my_streak() to authenticated;

drop function if exists public.leaderboard();
create or replace function public.leaderboard()
returns table (id uuid, username text, display_name text, avatar_url text, created_at timestamptz, points bigint, badge boolean, streak int)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.created_at,
         coalesce((select sum(r.amount) from public.rewards r where r.user_id = p.id and r.status <> 'cancelled'), 0)::bigint as points,
         p.badge,
         (case when p.last_claim_date >= public.today_utc() - 1 then p.daily_streak else 0 end)
  from public.profiles p
  where p.approved
  order by points desc, p.created_at asc
  limit 100
$$;

create or replace function public.public_profile(p_user uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select p.id, p.username, p.display_name, p.bio, p.location, p.avatar_url, p.banner_url, p.badge,
         (case when p.last_claim_date >= public.today_utc() - 1 then p.daily_streak else 0 end) as streak
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

revoke execute on function public.leaderboard(), public.public_profile(uuid) from public, anon;
grant execute on function public.leaderboard(), public.public_profile(uuid) to authenticated;
