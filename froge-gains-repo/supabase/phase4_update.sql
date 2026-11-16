-- Phase 4. Run in Supabase: SQL Editor > New query > paste all > Run. Safe to run more than once.

-- Counts how many people saw each local business (one count per person per business per day).
create table if not exists public.business_views (
  business_id bigint not null references public.businesses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null default current_date,
  primary key (business_id, user_id, day)
);
alter table public.business_views enable row level security;

create or replace function public.record_business_view(p_business bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.business_views (business_id, user_id) values (p_business, auth.uid())
    on conflict do nothing;
end $$;

create or replace function public.admin_business_views()
returns table (business_id bigint, views bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Admins only'; end if;
  return query
    select v.business_id, count(*) from public.business_views v group by v.business_id;
end $$;

revoke execute on function public.record_business_view(bigint), public.admin_business_views()
  from public, anon;
grant execute on function public.record_business_view(bigint), public.admin_business_views()
  to authenticated;
