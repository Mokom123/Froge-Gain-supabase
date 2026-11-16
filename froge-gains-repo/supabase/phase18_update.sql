-- Phase 18: status updates (24 hours) and the feed. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run more than once. For now ONLY ADMINS can post. Everyone can see.
-- To let every user post later, run:  update public.app_flags set on_ = true where key = 'users_post';

create table if not exists public.app_flags (key text primary key, on_ boolean not null default false);
insert into public.app_flags (key, on_) values ('users_post', false) on conflict (key) do nothing;
alter table public.app_flags enable row level security;
drop policy if exists "flags readable" on public.app_flags;
create policy "flags readable" on public.app_flags for select to authenticated using (true);

create or replace function public.can_post() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    public.is_admin() or coalesce((select on_ from public.app_flags where key = 'users_post'), false))
$$;
grant execute on function public.can_post() to authenticated;

-- Statuses: text, a photo or a short video. They disappear after 24 hours.
create table if not exists public.statuses (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('text', 'image', 'video')),
  body text,
  media_url text,
  bg int not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);
create index if not exists statuses_user_idx on public.statuses (user_id, id desc);
alter table public.statuses enable row level security;
drop policy if exists "read live statuses" on public.statuses;
create policy "read live statuses" on public.statuses for select to authenticated using (expires_at > now());
revoke insert, update, delete on public.statuses from authenticated, anon;

-- Feed posts.
create table if not exists public.posts (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('text', 'image', 'video')),
  body text,
  media_url text,
  created_at timestamptz not null default now()
);
create index if not exists posts_id_idx on public.posts (id desc);
alter table public.posts enable row level security;
drop policy if exists "read posts" on public.posts;
create policy "read posts" on public.posts for select to authenticated using (true);
revoke insert, update, delete on public.posts from authenticated, anon;

-- Public bucket for status and feed pictures and videos (only people allowed to post can upload).
insert into storage.buckets (id, name, public, file_size_limit)
values ('status', 'status', true, 52428800) on conflict (id) do nothing;
drop policy if exists "status upload" on storage.objects;
create policy "status upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'status' and public.can_post() and (storage.foldername(name))[1] = auth.uid()::text);

create or replace function public.post_status(p_kind text, p_body text default null, p_media text default null, p_bg int default 0)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_post() then raise exception 'Only admins can post a status for now'; end if;
  if p_kind not in ('text', 'image', 'video') then raise exception 'Bad type'; end if;
  if p_kind = 'text' and nullif(trim(coalesce(p_body, '')), '') is null then raise exception 'Write something first'; end if;
  if p_kind <> 'text' and p_media is null then raise exception 'Pick a file first'; end if;
  insert into public.statuses (user_id, kind, body, media_url, bg)
  values (auth.uid(), p_kind, left(p_body, 500), p_media, coalesce(p_bg, 0));
end $$;

create or replace function public.add_post(p_kind text, p_body text default null, p_media text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_post() then raise exception 'Only admins can post to the feed for now'; end if;
  if p_kind not in ('text', 'image', 'video') then raise exception 'Bad type'; end if;
  if p_kind = 'text' and nullif(trim(coalesce(p_body, '')), '') is null then raise exception 'Write something first'; end if;
  if p_kind <> 'text' and p_media is null then raise exception 'Pick a file first'; end if;
  insert into public.posts (user_id, kind, body, media_url) values (auth.uid(), p_kind, left(p_body, 2000), p_media);
end $$;

create or replace function public.delete_status(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.statuses where id = p_id and (user_id = auth.uid() or public.is_admin())
$$;
create or replace function public.delete_post(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.posts where id = p_id and (user_id = auth.uid() or public.is_admin())
$$;

create or replace function public.active_statuses()
returns table (id bigint, user_id uuid, username text, display_name text, avatar_url text, badge boolean,
               kind text, body text, media_url text, bg int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.user_id, p.username, p.display_name, p.avatar_url, p.badge,
         s.kind, s.body, s.media_url, s.bg, s.created_at
  from public.statuses s join public.profiles p on p.id = s.user_id
  where s.expires_at > now() and p.approved
  order by s.id
$$;

create or replace function public.feed_posts(p_limit int default 30)
returns table (id bigint, user_id uuid, username text, display_name text, avatar_url text, badge boolean,
               kind text, body text, media_url text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.user_id, p.username, p.display_name, p.avatar_url, p.badge,
         s.kind, s.body, s.media_url, s.created_at
  from public.posts s join public.profiles p on p.id = s.user_id
  where p.approved
  order by s.id desc
  limit least(coalesce(p_limit, 30), 100)
$$;

grant execute on function public.post_status(text, text, text, int), public.add_post(text, text, text),
  public.delete_status(bigint), public.delete_post(bigint), public.active_statuses(), public.feed_posts(int) to authenticated;
