-- Phase 12: KYC reviews, verified badges, airdrop list. Run once in Supabase -> SQL Editor.
-- (phase9, phase10 and phase11 must have been run before.)

-- 1. Verified badge (admins give it; nobody can give it to themselves).
alter table public.profiles add column if not exists badge boolean not null default false;

create or replace function public.admin_set_badge(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles set badge = p_on where id = p_user;
end $$;

-- 2. KYC: private picture bucket + submissions table.
insert into storage.buckets (id, name, public) values ('kyc', 'kyc', false) on conflict (id) do nothing;

drop policy if exists "kyc upload own" on storage.objects;
create policy "kyc upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'kyc' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "kyc read own or admin" on storage.objects;
create policy "kyc read own or admin" on storage.objects for select to authenticated
  using (bucket_id = 'kyc' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

create table if not exists public.kyc_submissions (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  full_name text not null,
  country text not null,
  doc_type text not null,
  doc_last4 text,
  doc_hash text not null,           -- fingerprint of the ID number, so one ID cannot back two accounts
  front_path text not null,
  back_path text,
  selfie_path text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note text,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz
);
alter table public.kyc_submissions enable row level security;
drop policy if exists "own kyc" on public.kyc_submissions;
create policy "own kyc" on public.kyc_submissions for select using (user_id = auth.uid());

create or replace function public.submit_kyc(p_full_name text, p_country text, p_doc_type text, p_doc_number text,
                                             p_front text, p_back text, p_selfie text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h text; cur text;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if length(trim(p_full_name)) < 3 or length(trim(p_country)) < 2 or length(trim(p_doc_number)) < 4 then
    raise exception 'Please fill in every field.';
  end if;
  select status into cur from public.kyc_submissions where user_id = auth.uid();
  if cur = 'approved' then raise exception 'You are already verified.'; end if;
  h := encode(digest(lower(regexp_replace(p_doc_number, '\s', '', 'g')), 'sha256'), 'hex');
  if exists (select 1 from public.kyc_submissions where doc_hash = h and user_id <> auth.uid() and status <> 'rejected') then
    raise exception 'This ID is already used by another account.';
  end if;
  insert into public.kyc_submissions (user_id, full_name, country, doc_type, doc_last4, doc_hash, front_path, back_path, selfie_path, status, note, submitted_at, reviewed_at)
  values (auth.uid(), trim(p_full_name), trim(p_country), p_doc_type, right(regexp_replace(p_doc_number, '\s', '', 'g'), 4), h,
          p_front, p_back, p_selfie, 'pending', null, now(), null)
  on conflict (user_id) do update set
    full_name = excluded.full_name, country = excluded.country, doc_type = excluded.doc_type, doc_last4 = excluded.doc_last4,
    doc_hash = excluded.doc_hash, front_path = excluded.front_path, back_path = excluded.back_path,
    selfie_path = excluded.selfie_path, status = 'pending', note = null, submitted_at = now(), reviewed_at = null;
end $$;

create or replace function public.my_kyc() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select json_build_object('status', status, 'note', note) from public.kyc_submissions where user_id = auth.uid()),
    json_build_object('status', 'none', 'note', null))
$$;

create or replace function public.admin_kyc_list(p_status text)
returns table (user_id uuid, username text, display_name text, full_name text, country text, doc_type text, doc_last4 text,
               front_path text, back_path text, selfie_path text, status text, note text, submitted_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select k.user_id, p.username, p.display_name, k.full_name, k.country, k.doc_type, k.doc_last4,
           k.front_path, k.back_path, k.selfie_path, k.status, k.note, k.submitted_at
    from public.kyc_submissions k join public.profiles p on p.id = k.user_id
    where p_status is null or k.status = p_status
    order by k.submitted_at desc;
end $$;

create or replace function public.admin_kyc_review(p_user uuid, p_approve boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.kyc_submissions
     set status = case when p_approve then 'approved' else 'rejected' end,
         note = nullif(trim(coalesce(p_note, '')), ''), reviewed_at = now()
   where user_id = p_user;
end $$;

-- 3. Admin user list now also shows wallet, KYC status and badge.
drop function if exists public.admin_list_users();
create or replace function public.admin_list_users()
returns table (id uuid, username text, display_name text, email text, approved boolean,
               suspended_until timestamptz, created_at timestamptz, points bigint, is_admin boolean,
               wallet_address text, wallet_verified boolean, kyc_status text, badge boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select p.id, p.username, p.display_name, u.email::text, p.approved, p.suspended_until, p.created_at,
           coalesce((select sum(r.amount) from public.rewards r where r.user_id = p.id and r.status <> 'cancelled'), 0)::bigint,
           p.is_admin, p.wallet_address, p.wallet_verified,
           coalesce((select k.status from public.kyc_submissions k where k.user_id = p.id), 'none'), p.badge
    from public.profiles p join auth.users u on u.id = p.id
    order by p.created_at desc;
end $$;

-- 4. The airdrop list: everyone with a linked wallet, with KYC status and TPoints.
create or replace function public.admin_airdrop_list()
returns table (username text, wallet_address text, wallet_verified boolean, kyc_status text, points bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select p.username, p.wallet_address, p.wallet_verified,
           coalesce((select k.status from public.kyc_submissions k where k.user_id = p.id), 'none'),
           coalesce((select sum(r.amount) from public.rewards r where r.user_id = p.id and r.status <> 'cancelled'), 0)::bigint
    from public.profiles p
    where p.wallet_address is not null
    order by 5 desc;
end $$;

-- 5. Leaderboard and public profile show the badge.
drop function if exists public.leaderboard();
create or replace function public.leaderboard()
returns table (id uuid, username text, display_name text, avatar_url text, created_at timestamptz, points bigint, badge boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url, p.created_at,
         coalesce((select sum(r.amount) from public.rewards r where r.user_id = p.id and r.status <> 'cancelled'), 0)::bigint as points,
         p.badge
  from public.profiles p
  where p.approved
  order by points desc, p.created_at asc
  limit 100
$$;

create or replace function public.public_profile(p_user uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  select p.id, p.username, p.display_name, p.bio, p.location, p.avatar_url, p.banner_url, p.badge
    into r from public.profiles p
   where p.id = p_user and (p.approved or p.id = auth.uid());
  if not found then raise exception 'Profile not found'; end if;
  return json_build_object(
    'id', r.id, 'username', r.username, 'display_name', r.display_name, 'bio', r.bio,
    'location', r.location, 'avatar_url', r.avatar_url, 'banner_url', r.banner_url, 'badge', r.badge,
    'followers', (select count(*) from public.follows where followed_id = p_user),
    'following', (select count(*) from public.follows where follower_id = p_user),
    'is_following', exists (select 1 from public.follows where follower_id = auth.uid() and followed_id = p_user),
    'is_me', p_user = auth.uid());
end $$;

revoke execute on function public.admin_set_badge(uuid, boolean), public.submit_kyc(text, text, text, text, text, text, text),
  public.my_kyc(), public.admin_kyc_list(text), public.admin_kyc_review(uuid, boolean, text),
  public.admin_list_users(), public.admin_airdrop_list(), public.leaderboard() from public, anon;
grant execute on function public.admin_set_badge(uuid, boolean), public.submit_kyc(text, text, text, text, text, text, text),
  public.my_kyc(), public.admin_kyc_list(text), public.admin_kyc_review(uuid, boolean, text),
  public.admin_list_users(), public.admin_airdrop_list(), public.leaderboard() to authenticated;
