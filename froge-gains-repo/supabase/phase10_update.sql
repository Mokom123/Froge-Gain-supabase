-- Phase 10: wallet address (read-only link). Run once in Supabase -> SQL Editor.
alter table public.profiles add column if not exists wallet_address text;

create or replace function public.set_wallet(p_addr text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_addr is not null and p_addr !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'That is not a valid wallet address.';
  end if;
  update public.profiles set wallet_address = p_addr where id = auth.uid();
end $$;
grant execute on function public.set_wallet(text) to authenticated;
