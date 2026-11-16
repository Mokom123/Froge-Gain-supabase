-- Phase 19: feed reactions (fire), comments, views, mute/not interested/block, tabs, and groups.
-- Run in Supabase: SQL Editor > New query > paste all > Run. Safe to run more than once. Needs phase18_update.sql first.

-- ---------------------------------------------------------------- ambassadors
alter table public.profiles add column if not exists is_ambassador boolean not null default false;

create or replace function public.admin_set_ambassador(p_user uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles set is_ambassador = p_on where id = p_user;
end $$;

create or replace function public.admin_ambassador_ids() returns setof uuid
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query select id from public.profiles where is_ambassador;
end $$;

-- Can this person create groups? Ambassadors and admins.
create or replace function public.can_create_group() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (public.is_admin()
    or coalesce((select is_ambassador from public.profiles where id = auth.uid()), false))
$$;

-- ---------------------------------------------------------------- feed: reactions, comments, views, hides, blocks
create table if not exists public.post_likes (
  post_id bigint not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id));
create table if not exists public.post_views (
  post_id bigint not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id));
create table if not exists public.post_comments (
  id bigint generated always as identity primary key,
  post_id bigint not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(body) between 1 and 500),
  created_at timestamptz not null default now());
create index if not exists post_comments_post_idx on public.post_comments (post_id, id);
create table if not exists public.post_hides (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id bigint not null references public.posts(id) on delete cascade,
  kind text not null default 'mute',
  primary key (user_id, post_id));
create table if not exists public.user_blocks (
  blocker uuid not null references public.profiles(id) on delete cascade,
  blocked uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked), check (blocker <> blocked));
alter table public.post_likes enable row level security;
alter table public.post_views enable row level security;
alter table public.post_comments enable row level security;
alter table public.post_hides enable row level security;
alter table public.user_blocks enable row level security;
-- No direct access: everything goes through the functions below.

drop function if exists public.feed_posts(int);
create or replace function public.feed_posts(p_tab text default 'latest', p_limit int default 30)
returns table (id bigint, user_id uuid, username text, display_name text, avatar_url text, badge boolean,
               kind text, body text, media_url text, created_at timestamptz,
               likes int, comments int, views int, liked boolean)
language sql stable security definer set search_path = public as $$
  with x as (
    select s.id, s.user_id, p.username, p.display_name, p.avatar_url, p.badge, s.kind, s.body, s.media_url, s.created_at,
           (select count(*)::int from public.post_likes l where l.post_id = s.id) as likes,
           (select count(*)::int from public.post_comments c where c.post_id = s.id) as comments,
           (select count(*)::int from public.post_views v where v.post_id = s.id) as views,
           exists (select 1 from public.post_likes l where l.post_id = s.id and l.user_id = auth.uid()) as liked
    from public.posts s join public.profiles p on p.id = s.user_id
    where p.approved
      and not exists (select 1 from public.post_hides h where h.user_id = auth.uid() and h.post_id = s.id)
      and not exists (select 1 from public.user_blocks b
                      where (b.blocker = auth.uid() and b.blocked = s.user_id) or (b.blocker = s.user_id and b.blocked = auth.uid()))
      and (p_tab <> 'mine' or s.user_id = auth.uid())
      and (p_tab <> 'trending' or s.created_at > now() - interval '7 days')
  )
  select * from x
  order by case when p_tab = 'trending' then x.likes * 3 + x.comments * 2 + x.views end desc nulls last, x.id desc
  limit least(coalesce(p_limit, 30), 100)
$$;

create or replace function public.toggle_like(p_post bigint) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); now_liked boolean;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if exists (select 1 from public.post_likes where post_id = p_post and user_id = uid) then
    delete from public.post_likes where post_id = p_post and user_id = uid; now_liked := false;
  else
    insert into public.post_likes (post_id, user_id) values (p_post, uid); now_liked := true;
    insert into public.post_views (post_id, user_id) values (p_post, uid) on conflict do nothing;
  end if;
  return json_build_object('liked', now_liked, 'likes', (select count(*) from public.post_likes where post_id = p_post));
end $$;

create or replace function public.record_views(p_ids bigint[]) returns void
language sql security definer set search_path = public as $$
  insert into public.post_views (post_id, user_id)
  select i, auth.uid() from unnest(p_ids) i
  where auth.uid() is not null and exists (select 1 from public.posts where id = i)
  on conflict do nothing
$$;

create or replace function public.add_comment(p_post bigint, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare t text := nullif(trim(coalesce(p_body, '')), '');
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if t is null then raise exception 'Write something first'; end if;
  if not exists (select 1 from public.posts where id = p_post) then raise exception 'Post not found'; end if;
  insert into public.post_comments (post_id, user_id, body) values (p_post, auth.uid(), left(t, 500));
  insert into public.post_views (post_id, user_id) values (p_post, auth.uid()) on conflict do nothing;
end $$;

create or replace function public.post_comment_list(p_post bigint)
returns table (id bigint, user_id uuid, username text, display_name text, avatar_url text, badge boolean, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select c.id, c.user_id, p.username, p.display_name, p.avatar_url, p.badge, c.body, c.created_at
  from public.post_comments c join public.profiles p on p.id = c.user_id
  where c.post_id = p_post
    and not exists (select 1 from public.user_blocks b where b.blocker = auth.uid() and b.blocked = c.user_id)
  order by c.id limit 300
$$;

create or replace function public.delete_comment(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.post_comments c where c.id = p_id and (
    c.user_id = auth.uid() or public.is_admin()
    or exists (select 1 from public.posts s where s.id = c.post_id and s.user_id = auth.uid()))
$$;

create or replace function public.hide_post(p_post bigint, p_kind text default 'mute') returns void
language sql security definer set search_path = public as $$
  insert into public.post_hides (user_id, post_id, kind)
  select auth.uid(), p_post, case when p_kind = 'not_interested' then 'not_interested' else 'mute' end
  where auth.uid() is not null
  on conflict do nothing
$$;

create or replace function public.block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_user = auth.uid() then raise exception 'You cannot block yourself'; end if;
  insert into public.user_blocks (blocker, blocked) values (auth.uid(), p_user) on conflict do nothing;
end $$;
create or replace function public.unblock_user(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.user_blocks where blocker = auth.uid() and blocked = p_user
$$;
create or replace function public.my_blocks() returns table (user_id uuid, username text, display_name text, avatar_url text)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url
  from public.user_blocks b join public.profiles p on p.id = b.blocked where b.blocker = auth.uid()
$$;

-- Blocked people (either way) cannot send each other messages.
create or replace function public.block_check_message() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.user_blocks b
             where (b.blocker = new.sender_id and b.blocked = new.recipient_id)
                or (b.blocker = new.recipient_id and b.blocked = new.sender_id)) then
    raise exception 'You cannot message this person';
  end if;
  return new;
end $$;
drop trigger if exists messages_block_check on public.messages;
create trigger messages_block_check before insert on public.messages
  for each row execute function public.block_check_message();

-- ---------------------------------------------------------------- groups
create table if not exists public.groups (
  id bigint generated always as identity primary key,
  name text not null check (length(trim(name)) between 2 and 40),
  description text check (description is null or length(description) <= 200),
  created_by uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now());
create table if not exists public.group_members (
  group_id bigint not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id));
create index if not exists group_members_user_idx on public.group_members (user_id);
create table if not exists public.group_messages (
  id bigint generated always as identity primary key,
  group_id bigint not null references public.groups(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (length(body) between 1 and 1000),
  created_at timestamptz not null default now());
create index if not exists group_messages_idx on public.group_messages (group_id, id desc);
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_messages enable row level security;
-- No direct access: everything goes through the functions below.

create or replace function public.is_group_member(p_group bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members where group_id = p_group and user_id = auth.uid())
$$;

create or replace function public.create_group(p_name text, p_desc text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare gid bigint;
begin
  if not public.can_create_group() then raise exception 'Only ambassadors can create groups'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  insert into public.groups (name, description, created_by)
  values (trim(p_name), nullif(trim(coalesce(p_desc, '')), ''), auth.uid()) returning id into gid;
  insert into public.group_members (group_id, user_id) values (gid, auth.uid());
  return gid;
end $$;

create or replace function public.join_group(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if not exists (select 1 from public.groups where id = p_id) then raise exception 'Group not found'; end if;
  insert into public.group_members (group_id, user_id) values (p_id, auth.uid()) on conflict do nothing;
end $$;

create or replace function public.leave_group(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.group_members where group_id = p_id and user_id = auth.uid()
$$;

create or replace function public.delete_group(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.groups where id = p_id and (created_by = auth.uid() or public.is_admin())
$$;

create or replace function public.my_groups()
returns table (id bigint, name text, description text, created_by uuid, members int, last_body text, last_at timestamptz, last_sender text)
language sql stable security definer set search_path = public as $$
  select g.id, g.name, g.description, g.created_by,
         (select count(*)::int from public.group_members m where m.group_id = g.id),
         lm.body, lm.created_at, lp.username
  from public.groups g
  join public.group_members me on me.group_id = g.id and me.user_id = auth.uid()
  left join lateral (select m.body, m.created_at, m.sender_id from public.group_messages m
                     where m.group_id = g.id order by m.id desc limit 1) lm on true
  left join public.profiles lp on lp.id = lm.sender_id
  order by coalesce(lm.created_at, g.created_at) desc
$$;

create or replace function public.discover_groups()
returns table (id bigint, name text, description text, created_by uuid, members int)
language sql stable security definer set search_path = public as $$
  select g.id, g.name, g.description, g.created_by, (select count(*)::int from public.group_members m where m.group_id = g.id)
  from public.groups g
  where not exists (select 1 from public.group_members me where me.group_id = g.id and me.user_id = auth.uid())
  order by 5 desc, g.id desc limit 100
$$;

create or replace function public.send_group_message(p_group bigint, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare t text := nullif(trim(coalesce(p_body, '')), '');
begin
  if not public.is_group_member(p_group) then raise exception 'Join the group first'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if t is null then raise exception 'Message is empty'; end if;
  insert into public.group_messages (group_id, sender_id, body) values (p_group, auth.uid(), left(t, 1000));
end $$;

create or replace function public.group_msgs(p_group bigint, p_after bigint default 0)
returns table (id bigint, sender_id uuid, username text, display_name text, avatar_url text, body text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_group_member(p_group) then raise exception 'Join the group first'; end if;
  return query
    select * from (
      select m.id, m.sender_id, p.username, p.display_name, p.avatar_url, m.body, m.created_at
      from public.group_messages m join public.profiles p on p.id = m.sender_id
      where m.group_id = p_group and m.id > coalesce(p_after, 0)
      order by m.id desc limit 80) t
    order by t.id;
end $$;

create or replace function public.group_member_list(p_group bigint)
returns table (user_id uuid, username text, display_name text, avatar_url text, badge boolean, is_owner boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_group_member(p_group) then raise exception 'Join the group first'; end if;
  return query
    select p.id, p.username, p.display_name, p.avatar_url, p.badge, (g.created_by = p.id)
    from public.group_members m join public.profiles p on p.id = m.user_id join public.groups g on g.id = m.group_id
    where m.group_id = p_group order by (g.created_by = p.id) desc, m.joined_at limit 300;
end $$;

grant execute on function
  public.admin_set_ambassador(uuid, boolean), public.admin_ambassador_ids(), public.can_create_group(),
  public.feed_posts(text, int), public.toggle_like(bigint), public.record_views(bigint[]),
  public.add_comment(bigint, text), public.post_comment_list(bigint), public.delete_comment(bigint),
  public.hide_post(bigint, text), public.block_user(uuid), public.unblock_user(uuid), public.my_blocks(),
  public.is_group_member(bigint), public.create_group(text, text), public.join_group(bigint), public.leave_group(bigint),
  public.delete_group(bigint), public.my_groups(), public.discover_groups(), public.send_group_message(bigint, text),
  public.group_msgs(bigint, bigint), public.group_member_list(bigint)
  to authenticated;
