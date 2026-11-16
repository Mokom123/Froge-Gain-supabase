-- Phase 7: real Telegram verification. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run more than once. Run it after phase5 and phase6.

-- Which Telegram account belongs to which Froge account (one Telegram account per Froge account).
create table if not exists public.telegram_links (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  tg_id bigint unique not null,
  tg_username text,
  created_at timestamptz not null default now()
);
alter table public.telegram_links enable row level security;
drop policy if exists "read own telegram link" on public.telegram_links;
create policy "read own telegram link" on public.telegram_links
  for select to authenticated using (auth.uid() = user_id);
revoke insert, update, delete on public.telegram_links from authenticated, anon;

-- One-time codes used when someone presses Start in the bot. Only the server can touch this table.
create table if not exists public.telegram_link_codes (
  code text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.telegram_link_codes enable row level security;
revoke all on public.telegram_link_codes from authenticated, anon;

create or replace function public.my_telegram() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select json_build_object('linked', true, 'username', tg_username)
       from public.telegram_links where user_id = auth.uid()),
    json_build_object('linked', false, 'username', null))
$$;
revoke execute on function public.my_telegram() from public, anon;
grant execute on function public.my_telegram() to authenticated;

-- Only the server (after checking with Telegram) can pay out a Telegram task.
create or replace function public.claim_telegram_task(p_user uuid, p_task text) returns int
language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  if not coalesce((select approved and (suspended_until is null or suspended_until <= now())
                   from public.profiles where id = p_user), false) then
    raise exception 'Your account is not active';
  end if;
  select * into t from public.tasks where id::text = p_task and active and platform = 'telegram';
  if not found then raise exception 'Task not available'; end if;
  insert into public.completions (user_id, task_id) values (p_user, p_task);
  insert into public.rewards (user_id, task_id, amount, status) values (p_user, p_task, t.points, 'claimable');
  return t.points;
exception when unique_violation then
  raise exception 'Task already completed';
end $$;
revoke execute on function public.claim_telegram_task(uuid, text) from public, anon, authenticated;
grant execute on function public.claim_telegram_task(uuid, text) to service_role;

-- The app can no longer claim a Telegram task directly. Other platforms are unchanged for now.
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
  insert into public.completions (user_id, task_id) values (uid, p_task_id);
  insert into public.rewards (user_id, task_id, amount, status) values (uid, p_task_id, t.points, 'claimable');
  return t.points;
exception when unique_violation then
  raise exception 'Task already completed';
end $$;
