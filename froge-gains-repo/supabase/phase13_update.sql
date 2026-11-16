-- Phase 13: push notifications. Run in Supabase: SQL Editor > New query > paste all > Run. Safe to run more than once.

create table if not exists public.device_tokens (
  token text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  platform text not null default 'android',
  updated_at timestamptz not null default now()
);
create index if not exists device_tokens_user_idx on public.device_tokens(user_id);
alter table public.device_tokens enable row level security;
-- No direct access from the app. Only the two functions below and the server can touch it.

create or replace function public.save_device_token(p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_token is null or length(p_token) < 20 then return; end if;
  insert into public.device_tokens (token, user_id, updated_at)
  values (p_token, auth.uid(), now())
  on conflict (token) do update set user_id = auth.uid(), updated_at = now();
end $$;

create or replace function public.remove_device_token(p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.device_tokens where token = p_token and user_id = auth.uid();
end $$;

grant execute on function public.save_device_token(text) to authenticated;
grant execute on function public.remove_device_token(text) to authenticated;
