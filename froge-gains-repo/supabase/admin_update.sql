-- Run in Supabase: SQL Editor > New query > paste all > Run. (After schema.sql.)

-- 1. Admin flag. Users cannot change it themselves (they can only update username and wallet_address).
alter table public.profiles add column if not exists is_admin boolean not null default false;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- 2. Tasks the admin creates. Telegram tasks can only be "join".
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  platform text not null check (platform in ('telegram', 'x')),
  kind text not null check (kind in ('join', 'like', 'repost', 'quote', 'comment')),
  title text not null,
  url text not null,
  points int not null check (points > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check ((platform = 'telegram' and kind = 'join') or (platform = 'x' and kind <> 'join'))
);

-- 3. Settings the admin controls (for example the size of the tester pool in FROGE).
create table public.app_settings (
  key text primary key,
  value numeric not null
);
insert into public.app_settings values ('tester_pool_froge', 0);

alter table public.tasks enable row level security;
alter table public.app_settings enable row level security;

create policy "read active tasks" on public.tasks
  for select to authenticated using (active or public.is_admin());
create policy "admins add tasks" on public.tasks
  for insert to authenticated with check (public.is_admin());
create policy "admins edit tasks" on public.tasks
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete tasks" on public.tasks
  for delete to authenticated using (public.is_admin());

create policy "read settings" on public.app_settings
  for select to authenticated using (true);
create policy "admins write settings" on public.app_settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 4. Admins can also edit and delete any business.
create policy "admins edit businesses" on public.businesses
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete any business" on public.businesses
  for delete to authenticated using (public.is_admin());

-- 5. Points. The app cannot write rewards directly; it calls this function instead.
-- NOTE: for now this credits points WITHOUT checking the action on X or Telegram.
create or replace function public.claim_task(p_task_id text) returns int
language plpgsql security definer set search_path = public as $$
declare
  t public.tasks;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into t from public.tasks where id::text = p_task_id and active;
  if not found then raise exception 'Task not available'; end if;
  insert into public.completions (user_id, task_id) values (uid, p_task_id);
  insert into public.rewards (user_id, task_id, amount, status)
    values (uid, p_task_id, t.points, 'claimable');
  return t.points;
exception when unique_violation then
  raise exception 'Task already completed';
end $$;

create or replace function public.my_points() returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::bigint from public.rewards
  where user_id = auth.uid() and status <> 'cancelled'
$$;

create or replace function public.total_points() returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::bigint from public.rewards where status <> 'cancelled'
$$;

create or replace function public.tester_count() returns bigint
language sql stable security definer set search_path = public as $$
  select count(*) from public.profiles
$$;

create or replace function public.task_counts() returns table (task_id text, done bigint)
language sql stable security definer set search_path = public as $$
  select c.task_id, count(*) from public.completions c group by c.task_id
$$;

revoke execute on function public.claim_task(text), public.my_points(),
  public.total_points(), public.tester_count(), public.task_counts() from public, anon;
grant execute on function public.claim_task(text), public.my_points(),
  public.total_points(), public.tester_count(), public.task_counts() to authenticated;

-- 6. Make yourself the admin. Replace YOUR_USERNAME with the username you signed up with, then run:
-- update public.profiles set is_admin = true where username = 'YOUR_USERNAME';
