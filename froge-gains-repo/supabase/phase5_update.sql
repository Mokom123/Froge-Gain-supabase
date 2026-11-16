-- Phase 5. Run in Supabase: SQL Editor > New query > paste all > Run. Safe to run more than once.

-- 1. A link for each ad (opens when the ad is tapped).
alter table public.ads add column if not exists link_url text;

-- 2. Notifications. A new task creates one for everybody automatically.
create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  kind text not null default 'task',
  title text not null,
  body text,
  task_id uuid references public.tasks(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.notifications enable row level security;
drop policy if exists "read notifications" on public.notifications;
create policy "read notifications" on public.notifications
  for select to authenticated using (true);

create or replace function public.notify_new_task() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.active then
    insert into public.notifications (kind, title, body, task_id)
    values (
      'task',
      'New task: ' || new.title,
      (case new.kind
         when 'join' then 'Join a Telegram group'
         when 'like' then 'Like a post on X'
         when 'repost' then 'Repost on X'
         when 'quote' then 'Quote a post on X'
         else 'Comment on a post on X'
       end) || ' · +' || new.points || ' TPoints',
      new.id);
  end if;
  return new;
end $$;

drop trigger if exists on_task_created on public.tasks;
create trigger on_task_created after insert on public.tasks
  for each row execute function public.notify_new_task();

-- 3. Support tickets and live chat. Written only through the functions below.
create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  email text,
  topic text not null,
  status text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.support_messages (
  id bigint generated always as identity primary key,
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  from_admin boolean not null default false,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists support_messages_ticket_idx on public.support_messages (ticket_id, id);

alter table public.support_tickets enable row level security;
alter table public.support_messages enable row level security;

drop policy if exists "read own or admin tickets" on public.support_tickets;
create policy "read own or admin tickets" on public.support_tickets
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

drop policy if exists "read own or admin messages" on public.support_messages;
create policy "read own or admin messages" on public.support_messages
  for select to authenticated using (
    exists (select 1 from public.support_tickets t
            where t.id = ticket_id and (t.user_id = auth.uid() or public.is_admin())));

create or replace function public.create_ticket(p_topic text, p_email text, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  tid uuid;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if char_length(coalesce(trim(p_body), '')) = 0 then raise exception 'Write a message first'; end if;
  insert into public.support_tickets (user_id, email, topic)
    values (uid, nullif(trim(p_email), ''), p_topic) returning id into tid;
  insert into public.support_messages (ticket_id, sender_id, from_admin, body)
    values (tid, uid, false, left(trim(p_body), 2000));
  return tid;
end $$;

create or replace function public.send_support_message(p_ticket uuid, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  t public.support_tickets;
  adm boolean := public.is_admin();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into t from public.support_tickets where id = p_ticket;
  if not found or (t.user_id <> uid and not adm) then raise exception 'Ticket not found'; end if;
  if t.status = 'closed' and not adm then raise exception 'This ticket is closed'; end if;
  if char_length(coalesce(trim(p_body), '')) = 0 then raise exception 'Write a message first'; end if;
  insert into public.support_messages (ticket_id, sender_id, from_admin, body)
    values (p_ticket, uid, adm and t.user_id <> uid, left(trim(p_body), 2000));
  update public.support_tickets set updated_at = now() where id = p_ticket;
end $$;

create or replace function public.admin_set_ticket_status(p_ticket uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.support_tickets set status = p_status, updated_at = now() where id = p_ticket;
end $$;

create or replace function public.admin_list_tickets(p_status text)
returns table (id uuid, topic text, status text, email text, username text, display_name text,
               created_at timestamptz, updated_at timestamptz, last_message text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select t.id, t.topic, t.status, t.email, p.username, p.display_name, t.created_at, t.updated_at,
           (select m.body from public.support_messages m where m.ticket_id = t.id order by m.id desc limit 1)
    from public.support_tickets t
    join public.profiles p on p.id = t.user_id
    where t.status = p_status
    order by t.updated_at desc;
end $$;

revoke execute on function public.create_ticket(text, text, text), public.send_support_message(uuid, text),
  public.admin_set_ticket_status(uuid, text), public.admin_list_tickets(text) from public, anon;
grant execute on function public.create_ticket(text, text, text), public.send_support_message(uuid, text),
  public.admin_set_ticket_status(uuid, text), public.admin_list_tickets(text) to authenticated;
