-- Phase 2. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Needs phase1_update.sql to have been run first. Safe to run more than once.

-- 1. FIX for "new row violates row-level security policy" on profile pictures.
-- Replaces the picture policies and adds the missing "read" policy.
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true)
  on conflict (id) do update set public = true;

drop policy if exists "upload own profile images" on storage.objects;
drop policy if exists "replace own profile images" on storage.objects;
drop policy if exists "delete own profile images" on storage.objects;
drop policy if exists "read own profile images" on storage.objects;

create policy "upload own profile images" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "read own profile images" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "replace own profile images" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "delete own profile images" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- 2. Task pictures (channel or account photo, or one the admin uploads).
alter table public.tasks add column if not exists icon_url text;

-- 3. Reactions (one flame per person per task). Changed only through the function below.
create table if not exists public.task_reactions (
  task_id uuid not null references public.tasks(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (task_id, user_id)
);
alter table public.task_reactions enable row level security;

create or replace function public.toggle_reaction(p_task_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if exists (select 1 from public.task_reactions where task_id = p_task_id and user_id = uid) then
    delete from public.task_reactions where task_id = p_task_id and user_id = uid;
    return false;
  end if;
  insert into public.task_reactions (task_id, user_id) values (p_task_id, uid);
  return true;
end $$;

-- 4. Counts for every active task: how many completed it, reactions, and whether I reacted.
create or replace function public.task_stats()
returns table (task_id text, done bigint, reactions bigint, mine boolean)
language sql stable security definer set search_path = public as $$
  select t.id::text,
    (select count(*) from public.completions c where c.task_id = t.id::text),
    (select count(*) from public.task_reactions r where r.task_id = t.id),
    exists (select 1 from public.task_reactions r where r.task_id = t.id and r.user_id = auth.uid())
  from public.tasks t
  where t.active
$$;

-- 5. Who completed a task (name and picture only), newest first.
create or replace function public.task_completers(p_task_id text)
returns table (username text, display_name text, avatar_url text, completed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.username, p.display_name, p.avatar_url, c.created_at
  from public.completions c
  join public.profiles p on p.id = c.user_id
  where c.task_id = p_task_id
  order by c.created_at desc
  limit 100
$$;

revoke execute on function public.toggle_reaction(uuid), public.task_stats(),
  public.task_completers(text) from public, anon;
grant execute on function public.toggle_reaction(uuid), public.task_stats(),
  public.task_completers(text) to authenticated;
