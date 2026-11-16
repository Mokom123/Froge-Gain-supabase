-- Phase 14: invitation codes made from each person's account id. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run more than once. Existing people get a code automatically.

alter table public.profiles
  add column if not exists referral_code text
  generated always as (upper(substr(replace(id::text, '-', ''), 1, 8))) stored;
create index if not exists profiles_referral_code_idx on public.profiles (referral_code);

-- A new person can type the invitation code (or, as before, the inviter's username).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inviter uuid; r text;
begin
  r := upper(regexp_replace(coalesce(new.raw_user_meta_data->>'referral', ''), '[^A-Za-z0-9_]', '', 'g'));
  if r <> '' then
    select id into inviter from public.profiles where referral_code = r limit 1;
    if inviter is null then
      select id into inviter from public.profiles where upper(username) = r limit 1;
    end if;
  end if;
  insert into public.profiles (id, username, referred_by)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1)), inviter);
  return new;
end $$;
