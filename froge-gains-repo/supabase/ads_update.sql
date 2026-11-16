-- Run in Supabase: SQL Editor > New query > paste all > Run. (After admin_update.sql.)

create table public.ads (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  tag text,
  image_url text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.ads enable row level security;

create policy "read ads" on public.ads
  for select to anon, authenticated using (active or public.is_admin());
create policy "admins add ads" on public.ads
  for insert to authenticated with check (public.is_admin());
create policy "admins edit ads" on public.ads
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins delete ads" on public.ads
  for delete to authenticated using (public.is_admin());

-- Public storage bucket for ad images. Only admins can upload or delete.
insert into storage.buckets (id, name, public) values ('ads', 'ads', true)
  on conflict (id) do nothing;

create policy "admins upload ad images" on storage.objects
  for insert to authenticated with check (bucket_id = 'ads' and public.is_admin());
create policy "admins delete ad images" on storage.objects
  for delete to authenticated using (bucket_id = 'ads' and public.is_admin());
