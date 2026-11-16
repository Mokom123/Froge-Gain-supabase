-- Phase 3. Run in Supabase: SQL Editor > New query > paste all > Run.
-- Needs phase1 and phase2 to have been run first. Safe to run more than once.

-- 1. Approval and suspension. Everyone who already has an account stays approved.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'profiles' and column_name = 'approved') then
    alter table public.profiles add column approved boolean not null default false;
    update public.profiles set approved = true;
  end if;
end $$;
alter table public.profiles add column if not exists suspended_until timestamptz;

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select approved and (suspended_until is null or suspended_until <= now())
                   from public.profiles where id = auth.uid()), false)
$$;

-- Pending or suspended accounts cannot claim tasks or react.
create or replace function public.claim_task(p_task_id text) returns int
language plpgsql security definer set search_path = public as $$
declare
  t public.tasks;
  uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  select * into t from public.tasks where id::text = p_task_id and active;
  if not found then raise exception 'Task not available'; end if;
  insert into public.completions (user_id, task_id) values (uid, p_task_id);
  insert into public.rewards (user_id, task_id, amount, status)
    values (uid, p_task_id, t.points, 'claimable');
  return t.points;
exception when unique_violation then
  raise exception 'Task already completed';
end $$;

create or replace function public.toggle_reaction(p_task_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if exists (select 1 from public.task_reactions where task_id = p_task_id and user_id = uid) then
    delete from public.task_reactions where task_id = p_task_id and user_id = uid;
    return false;
  end if;
  insert into public.task_reactions (task_id, user_id) values (p_task_id, uid);
  return true;
end $$;

-- 2. Admin tools for users. Each one checks that the caller is an admin.
create or replace function public.admin_list_users()
returns table (id uuid, username text, display_name text, email text, approved boolean,
               suspended_until timestamptz, created_at timestamptz, points bigint, is_admin boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select p.id, p.username, p.display_name, u.email::text, p.approved, p.suspended_until, p.created_at,
           coalesce((select sum(r.amount) from public.rewards r
                     where r.user_id = p.id and r.status <> 'cancelled'), 0)::bigint,
           p.is_admin
    from public.profiles p
    join auth.users u on u.id = p.id
    order by p.created_at desc;
end $$;

create or replace function public.admin_set_approved(p_user uuid, p_approved boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles set approved = p_approved where id = p_user;
end $$;

-- p_hours = how long to suspend for. Use 0 to lift a suspension. Admins cannot be suspended.
create or replace function public.admin_suspend_user(p_user uuid, p_hours int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  update public.profiles
     set suspended_until = case when p_hours > 0 then now() + (p_hours * interval '1 hour') else null end
   where id = p_user and is_admin = false;
end $$;

-- Deletes the account and everything linked to it. You cannot delete yourself or another admin here.
create or replace function public.admin_delete_user(p_user uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  if p_user = auth.uid() then raise exception 'You cannot delete yourself'; end if;
  if exists (select 1 from public.profiles where id = p_user and is_admin) then
    raise exception 'Admins cannot be deleted here';
  end if;
  delete from auth.users where id = p_user;
end $$;

revoke execute on function public.is_active_user(), public.admin_list_users(),
  public.admin_set_approved(uuid, boolean), public.admin_suspend_user(uuid, int),
  public.admin_delete_user(uuid) from public, anon;
grant execute on function public.is_active_user(), public.admin_list_users(),
  public.admin_set_approved(uuid, boolean), public.admin_suspend_user(uuid, int),
  public.admin_delete_user(uuid) to authenticated;

-- 3. TPoints per task type. The admin edits these; new tasks pick the right value automatically.
insert into public.app_settings (key, value) values
  ('points_join', 10), ('points_like', 3), ('points_repost', 8),
  ('points_quote', 15), ('points_comment', 20)
on conflict (key) do nothing;

-- 4. Businesses: picture, short description, website.
alter table public.businesses add column if not exists image_url text;
alter table public.businesses add column if not exists description text;
alter table public.businesses add column if not exists website text;
grant insert (image_url, description, website), update (image_url, description, website)
  on public.businesses to authenticated;
