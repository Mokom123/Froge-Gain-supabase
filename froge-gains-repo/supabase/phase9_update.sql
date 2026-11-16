-- Phase 9: leaderboard. Run once in Supabase -> SQL Editor.
create or replace function public.leaderboard()
returns table (id uuid, username text, display_name text, avatar_url text, created_at timestamptz, points bigint)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.created_at,
         coalesce((select sum(r.amount) from public.rewards r where r.user_id = p.id and r.status <> 'cancelled'), 0)::bigint as points
  from public.profiles p
  where p.approved
  order by points desc, p.created_at asc
  limit 100
$$;
grant execute on function public.leaderboard() to authenticated;
