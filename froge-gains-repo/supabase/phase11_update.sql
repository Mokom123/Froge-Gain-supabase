-- Phase 11: verified wallets (the wallet stays with the person; the app holds nothing). Run once in Supabase -> SQL Editor (after phase10).
alter table public.profiles add column if not exists wallet_verified boolean not null default false;

-- Typing an address by hand never counts as verified.
create or replace function public.set_wallet(p_addr text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_addr is not null and p_addr !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'That is not a valid wallet address.';
  end if;
  update public.profiles
     set wallet_address = p_addr, wallet_verified = false
   where id = auth.uid();
end $$;
grant execute on function public.set_wallet(text) to authenticated;

-- Nobody can mark their own wallet as verified from the app.
revoke update (wallet_verified) on public.profiles from authenticated;

create table if not exists public.wallet_nonces (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  message text not null,
  created_at timestamptz not null default now()
);
alter table public.wallet_nonces enable row level security;  -- only the function (service role) uses it
