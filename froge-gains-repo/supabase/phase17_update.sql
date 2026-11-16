-- Phase 17: chat (text, voice notes, photos, videos, stickers). Run in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to run more than once. Text messages are kept. Photos, videos and voice notes are deleted after 14 days
-- (see phase17b_schedule.sql and the chat-cleanup function).

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('text', 'image', 'video', 'voice', 'sticker')),
  body text,                 -- the text, or the sticker id
  media_path text,           -- file in the private "chat" bucket
  thumb text,                -- tiny picture kept after the file is deleted (base64)
  duration_ms int,
  media_gone boolean not null default false,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender_id <> recipient_id)
);
create index if not exists messages_sender_idx on public.messages (sender_id, recipient_id, id desc);
create index if not exists messages_recipient_idx on public.messages (recipient_id, sender_id, id desc);
create index if not exists messages_unread_idx on public.messages (recipient_id) where read_at is null;
alter table public.messages enable row level security;
drop policy if exists "read own messages" on public.messages;
create policy "read own messages" on public.messages
  for select to authenticated using (sender_id = auth.uid() or recipient_id = auth.uid());
revoke insert, update, delete on public.messages from authenticated, anon;

-- Private storage for chat media. Max 25 MB per file.
insert into storage.buckets (id, name, public, file_size_limit)
values ('chat', 'chat', false, 26214400) on conflict (id) do nothing;
drop policy if exists "chat upload own" on storage.objects;
create policy "chat upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "chat read involved" on storage.objects;
create policy "chat read involved" on storage.objects for select to authenticated
  using (bucket_id = 'chat' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.messages m where m.media_path = storage.objects.name and m.recipient_id = auth.uid())));

-- Send a message. Returns the saved message.
create or replace function public.send_message(
  p_to uuid, p_kind text, p_body text default null, p_media text default null,
  p_thumb text default null, p_duration int default null) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  m public.messages;
  nm text;
  preview text;
  txt text := nullif(trim(coalesce(p_body, '')), '');
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if p_to = uid then raise exception 'You cannot message yourself'; end if;
  if not exists (select 1 from public.profiles where id = p_to and approved) then
    raise exception 'This person is not available';
  end if;
  if p_kind not in ('text', 'image', 'video', 'voice', 'sticker') then raise exception 'Bad message type'; end if;
  if p_kind in ('text', 'sticker') and txt is null then raise exception 'Message is empty'; end if;
  if p_kind = 'text' and length(txt) > 2000 then raise exception 'Message is too long'; end if;
  if p_kind in ('image', 'video', 'voice') and (p_media is null or split_part(p_media, '/', 1) <> uid::text) then
    raise exception 'Missing media';
  end if;
  if p_thumb is not null and length(p_thumb) > 60000 then raise exception 'Thumbnail too large'; end if;
  -- no more than 30 messages a minute
  if (select count(*) from public.messages where sender_id = uid and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'Slow down a little';
  end if;

  insert into public.messages (sender_id, recipient_id, kind, body, media_path, thumb, duration_ms)
  values (uid, p_to, p_kind,
          case when p_kind in ('text', 'sticker') then txt else null end,
          p_media, p_thumb, p_duration)
  returning * into m;

  -- A phone notification, at most one every 5 minutes per sender.
  if not exists (select 1 from public.notifications
                 where kind = 'message' and user_id = p_to and actor_id = uid
                   and created_at > now() - interval '5 minutes') then
    select coalesce(nullif(trim(display_name), ''), username) into nm from public.profiles where id = uid;
    preview := case p_kind when 'text' then left(txt, 80) when 'image' then 'Sent a photo'
                           when 'video' then 'Sent a video' when 'voice' then 'Sent a voice message'
                           else 'Sent a sticker' end;
    insert into public.notifications (kind, title, body, user_id, actor_id)
    values ('message', nm || ' sent you a message', preview, p_to, uid);
  end if;
  return to_json(m);
end $$;

create or replace function public.mark_read(p_peer uuid) returns void
language sql security definer set search_path = public as $$
  update public.messages set read_at = now()
   where recipient_id = auth.uid() and sender_id = p_peer and read_at is null
$$;

create or replace function public.chat_unread_count() returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.messages where recipient_id = auth.uid() and read_at is null
$$;

-- One row per person you chat with: the latest message and how many you have not read.
create or replace function public.my_conversations()
returns table (peer_id uuid, username text, display_name text, avatar_url text, badge boolean,
               last_kind text, last_body text, last_at timestamptz, last_from_me boolean, unread int)
language sql stable security definer set search_path = public as $$
  with m as (
    select x.*, case when x.sender_id = auth.uid() then x.recipient_id else x.sender_id end as peer
    from public.messages x
    where x.sender_id = auth.uid() or x.recipient_id = auth.uid()
  ),
  l as (select distinct on (peer) * from m order by peer, id desc)
  select l.peer, p.username, p.display_name, p.avatar_url, p.badge,
         l.kind, l.body, l.created_at, (l.sender_id = auth.uid()),
         (select count(*)::int from public.messages u
           where u.recipient_id = auth.uid() and u.sender_id = l.peer and u.read_at is null)
  from l join public.profiles p on p.id = l.peer
  order by l.created_at desc
  limit 100
$$;

-- For the cleanup function only: chat files older than 14 days, and marking their messages.
create or replace function public.chat_expired_files() returns table (name text)
language sql stable security definer set search_path = public as $$
  select o.name from storage.objects o
  where o.bucket_id = 'chat' and o.created_at < now() - interval '14 days'
  limit 500
$$;
create or replace function public.chat_mark_gone(p_names text[]) returns void
language sql security definer set search_path = public as $$
  update public.messages set media_gone = true, media_path = null where media_path = any(p_names)
$$;
revoke execute on function public.chat_expired_files(), public.chat_mark_gone(text[]) from public, anon, authenticated;
grant execute on function public.chat_expired_files(), public.chat_mark_gone(text[]) to service_role;

revoke execute on function public.send_message(uuid, text, text, text, text, int), public.mark_read(uuid),
  public.chat_unread_count(), public.my_conversations() from public, anon;
grant execute on function public.send_message(uuid, text, text, text, text, int), public.mark_read(uuid),
  public.chat_unread_count(), public.my_conversations() to authenticated;
