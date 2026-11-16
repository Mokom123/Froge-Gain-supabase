-- Phase 22: ads can be placed on the Home (Earn) page or on the Games page.
alter table public.ads add column if not exists placement text not null default 'home';
alter table public.ads drop constraint if exists ads_placement_check;
alter table public.ads add constraint ads_placement_check check (placement in ('home','games'));
