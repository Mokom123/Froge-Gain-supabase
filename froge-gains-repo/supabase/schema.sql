-- Froge database. In Supabase: SQL Editor > New query > paste all of this > Run.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (char_length(username) between 3 and 24),
  wallet_address text,
  referred_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.linked_accounts (
  user_id uuid not null references public.profiles(id) on delete cascade,
  platform text not null check (platform in ('x', 'telegram')),
  handle text not null,
  verified boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (user_id, platform),
  unique (platform, handle) -- one Froge account per social account
);

create table public.completions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  task_id text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, task_id) -- one reward per task per person
);

create table public.rewards (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  task_id text not null,
  amount numeric not null check (amount > 0),
  status text not null default 'pending'
    check (status in ('pending', 'claimable', 'claimed', 'cancelled')),
  release_at timestamptz not null default now() + interval '24 hours',
  created_at timestamptz not null default now(),
  unique (user_id, task_id)
);

create table public.businesses (
  id bigint generated always as identity primary key,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  category text,
  city text,
  boosted boolean not null default false,
  created_at timestamptz not null default now()
);

-- Create a profile automatically when someone signs up.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1))
  );
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Row-level security: people can only see their own data.
alter table public.profiles enable row level security;
alter table public.linked_accounts enable row level security;
alter table public.completions enable row level security;
alter table public.rewards enable row level security;
alter table public.businesses enable row level security;

create policy "read own profile" on public.profiles
  for select to authenticated using (auth.uid() = id);
create policy "update own profile" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);
create policy "read own links" on public.linked_accounts
  for select to authenticated using (auth.uid() = user_id);
create policy "read own completions" on public.completions
  for select to authenticated using (auth.uid() = user_id);
create policy "read own rewards" on public.rewards
  for select to authenticated using (auth.uid() = user_id);
create policy "signed-in users read businesses" on public.businesses
  for select to authenticated using (true);
create policy "owners add businesses" on public.businesses
  for insert to authenticated with check (auth.uid() = owner_id);
create policy "owners edit businesses" on public.businesses
  for update to authenticated using (auth.uid() = owner_id) with check (auth.uid() = owner_id);
create policy "owners delete businesses" on public.businesses
  for delete to authenticated using (auth.uid() = owner_id);

-- The app can change only these columns. Rewards, completions, linked accounts
-- and the "boosted" flag are written by server code only, never by the app.
revoke update on public.profiles from authenticated;
grant update (username, wallet_address) on public.profiles to authenticated;
revoke insert, update on public.businesses from authenticated;
grant insert (owner_id, name, category, city),
      update (name, category, city) on public.businesses to authenticated;
