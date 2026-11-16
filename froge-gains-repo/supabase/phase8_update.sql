-- Phase 8: link X accounts with "Sign in with X". Run in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run more than once.

create table if not exists public.x_links (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  x_id text unique not null,
  x_username text,
  created_at timestamptz not null default now()
);
alter table public.x_links enable row level security;
drop policy if exists "read own x link" on public.x_links;
create policy "read own x link" on public.x_links
  for select to authenticated using (auth.uid() = user_id);
revoke insert, update, delete on public.x_links from authenticated, anon;

-- Temporary data for one sign-in attempt. Only the server can touch this table.
create table if not exists public.x_oauth_states (
  state text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  verifier text not null,
  created_at timestamptz not null default now()
);
alter table public.x_oauth_states enable row level security;
revoke all on public.x_oauth_states from authenticated, anon;

create or replace function public.my_x() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select json_build_object('linked', true, 'username', x_username)
       from public.x_links where user_id = auth.uid()),
    json_build_object('linked', false, 'username', null))
$$;
revoke execute on function public.my_x() from public, anon;
grant execute on function public.my_x() to authenticated;
