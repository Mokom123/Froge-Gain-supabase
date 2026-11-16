-- Phase 20: games (Ludo first), FGP bets, open games lobby, live or take-your-time play, plus game alerts.
-- Run in Supabase: SQL Editor > New query > paste all > Run. Safe to run more than once.
-- Pool (8-ball, 15-ball) is listed in the app as "coming soon": it needs its own engine and comes in the next update.

-- Bets are held as negative FGP rows, so the allowed range for a reward row changes from "above 0" to "not 0".
alter table public.rewards drop constraint if exists rewards_amount_check;
alter table public.rewards add constraint rewards_amount_check check (amount <> 0);

-- A game alert can point to the game.
alter table public.notifications add column if not exists game_id bigint;

create table if not exists public.games (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('ludo', 'pool8', 'pool15')),
  stake int not null check (stake between 1 and 100000),
  mode text not null check (mode in ('live', 'async')),
  limit_hours int not null default 24 check (limit_hours between 1 and 168),
  status text not null default 'open' check (status in ('open', 'active', 'finished', 'cancelled')),
  creator uuid not null references public.profiles(id) on delete cascade,
  opponent uuid references public.profiles(id) on delete cascade,
  turn uuid,
  state jsonb not null default '{}'::jsonb,
  winner uuid,
  result text,
  turn_deadline timestamptz,
  seen_a timestamptz,
  seen_b timestamptz,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  last_move_at timestamptz
);
create index if not exists games_open_idx on public.games (status, kind, id desc);
create index if not exists games_creator_idx on public.games (creator, status);
create index if not exists games_opponent_idx on public.games (opponent, status);
alter table public.games enable row level security;
-- No direct access: everything goes through the functions below.

-- ---------------------------------------------------------------- helpers
create or replace function public.points_of(p_user uuid) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::bigint from public.rewards where user_id = p_user and status <> 'cancelled'
$$;
revoke execute on function public.points_of(uuid) from public, anon, authenticated;

create or replace function public.jarr(j jsonb) returns int[]
language sql immutable as $$
  select coalesce(array_agg(x::int order by n), '{}') from jsonb_array_elements_text(j) with ordinality t(x, n)
$$;

create or replace function public.game_notify(p_user uuid, p_title text, p_body text, p_game bigint, p_actor uuid default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null then return; end if;
  if exists (select 1 from public.notifications where kind = 'game' and user_id = p_user and game_id = p_game
             and created_at > now() - interval '2 minutes') then return; end if;
  insert into public.notifications (kind, title, body, user_id, actor_id, game_id)
  values ('game', p_title, p_body, p_user, p_actor, p_game);
exception when others then null;
end $$;
revoke execute on function public.game_notify(uuid, text, text, bigint, uuid) from public, anon, authenticated;

create or replace function public.game_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'ludo' then 'Ludo' when 'pool8' then '8-ball pool' else '15-ball pool' end
$$;

-- Ends a game and pays the winner both stakes.
create or replace function public.game_finish(p_id bigint, p_winner uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games; loser uuid;
begin
  select * into g from public.games where id = p_id for update;
  if g.status <> 'active' then return; end if;
  loser := case when p_winner = g.creator then g.opponent else g.creator end;
  update public.games set status = 'finished', winner = p_winner, result = p_reason, turn = null,
         turn_deadline = null, finished_at = now() where id = p_id;
  insert into public.rewards (user_id, task_id, amount, status)
  values (p_winner, 'game:' || p_id || ':win', g.stake * 2, 'claimed') on conflict do nothing;
  perform public.game_notify(p_winner, 'You won ' || public.game_label(g.kind) || '!', '+' || g.stake || ' FGP (' || p_reason || ')', p_id);
  perform public.game_notify(loser, 'You lost ' || public.game_label(g.kind), '-' || g.stake || ' FGP (' || p_reason || ')', p_id);
end $$;
revoke execute on function public.game_finish(bigint, uuid, text) from public, anon, authenticated;

-- Both players get their stake back.
create or replace function public.game_refund(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  select * into g from public.games where id = p_id for update;
  if g.status not in ('open', 'active') then return; end if;
  update public.rewards set status = 'cancelled' where task_id like 'game:' || p_id || ':stake:%';
  update public.games set status = 'cancelled', result = p_reason, turn = null, turn_deadline = null, finished_at = now() where id = p_id;
  if g.status = 'active' then
    perform public.game_notify(g.creator, 'Game cancelled', 'Your stake was returned', p_id);
    perform public.game_notify(g.opponent, 'Game cancelled', 'Your stake was returned', p_id);
  end if;
end $$;
revoke execute on function public.game_refund(bigint, text) from public, anon, authenticated;

-- Looks for a player who ran out of time or left a live game. Safe to call any time.
create or replace function public.game_check(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games; a_gone boolean; b_gone boolean;
begin
  select * into g from public.games where id = p_id;
  if g.status = 'open' then
    if g.created_at < now() - interval '14 days' then perform public.game_refund(p_id, 'Nobody joined in time'); end if;
    return;
  end if;
  if g.status <> 'active' then return; end if;
  if g.mode = 'live' then
    a_gone := coalesce(g.seen_a, g.started_at) < now() - interval '60 seconds';
    b_gone := coalesce(g.seen_b, g.started_at) < now() - interval '60 seconds';
    if a_gone and b_gone then perform public.game_refund(p_id, 'Both players left'); return; end if;
    if a_gone then perform public.game_finish(p_id, g.opponent, 'Opponent left the game'); return; end if;
    if b_gone then perform public.game_finish(p_id, g.creator, 'Opponent left the game'); return; end if;
  end if;
  if g.turn_deadline is not null and g.turn_deadline < now() then
    perform public.game_finish(p_id, case when g.turn = g.creator then g.opponent else g.creator end, 'Opponent ran out of time');
  end if;
end $$;
revoke execute on function public.game_check(bigint) from public, anon, authenticated;

-- Sweeps every game (the optional cron job calls this each minute).
create or replace function public.game_sweep() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from public.games where status in ('open', 'active') limit 500 loop
    perform public.game_check(r.id);
  end loop;
end $$;
revoke execute on function public.game_sweep() from public, anon, authenticated;

-- The picture of a game that the app draws.
create or replace function public.game_view(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare g public.games; uid uuid := auth.uid();
begin
  select * into g from public.games where id = p_id;
  if not found then raise exception 'Game not found'; end if;
  if g.creator <> uid and coalesce(g.opponent, uid) <> uid then raise exception 'This is not your game'; end if;
  return json_build_object(
    'id', g.id, 'kind', g.kind, 'stake', g.stake, 'mode', g.mode, 'limit_hours', g.limit_hours, 'status', g.status,
    'turn', g.turn, 'state', g.state, 'winner', g.winner, 'result', g.result, 'deadline', g.turn_deadline,
    'now', now(), 'me', case when uid = g.creator then 'a' else 'b' end,
    'creator', (select json_build_object('id', p.id, 'name', coalesce(nullif(trim(p.display_name), ''), p.username), 'avatar', p.avatar_url, 'badge', p.badge)
                from public.profiles p where p.id = g.creator),
    'opponent', (select json_build_object('id', p.id, 'name', coalesce(nullif(trim(p.display_name), ''), p.username), 'avatar', p.avatar_url, 'badge', p.badge)
                 from public.profiles p where p.id = g.opponent));
end $$;

-- ---------------------------------------------------------------- lobby
create or replace function public.create_game(p_kind text, p_stake int, p_mode text, p_hours int default 24) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); gid bigint;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if p_kind <> 'ludo' then raise exception 'This game is coming soon'; end if;
  if p_stake is null or p_stake < 1 or p_stake > 100000 then raise exception 'Pick a bet between 1 and 100000 FGP'; end if;
  if p_mode not in ('live', 'async') then raise exception 'Bad mode'; end if;
  if p_mode = 'async' and p_hours not in (1, 6, 24, 72, 168) then raise exception 'Pick how long each move may take'; end if;
  perform 1 from public.profiles where id = uid for update;  -- stops two bets at once from overspending
  if (select count(*) from public.games where creator = uid and status = 'open') >= 5 then
    raise exception 'You already have 5 open games. Cancel one first.';
  end if;
  if public.points_of(uid) < p_stake then raise exception 'You do not have enough FGP for this bet'; end if;
  insert into public.games (kind, stake, mode, limit_hours, creator, seen_a)
  values (p_kind, p_stake, p_mode, case when p_mode = 'async' then p_hours else 24 end, uid, now()) returning id into gid;
  insert into public.rewards (user_id, task_id, amount, status) values (uid, 'game:' || gid || ':stake:' || uid, -p_stake, 'claimed');
  return gid;
end $$;

create or replace function public.cancel_game(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games;
begin
  select * into g from public.games where id = p_id for update;
  if not found or g.creator <> auth.uid() then raise exception 'Not your game'; end if;
  if g.status <> 'open' then raise exception 'This game already started'; end if;
  perform public.game_refund(p_id, 'Cancelled by the creator');
end $$;

create or replace function public.list_games(p_kind text default null, p_q text default null)
returns table (id bigint, kind text, stake int, mode text, limit_hours int, created_at timestamptz,
               creator_id uuid, creator_name text, creator_avatar text, creator_badge boolean)
language sql stable security definer set search_path = public as $$
  select g.id, g.kind, g.stake, g.mode, g.limit_hours, g.created_at, p.id,
         coalesce(nullif(trim(p.display_name), ''), p.username), p.avatar_url, p.badge
  from public.games g join public.profiles p on p.id = g.creator
  where g.status = 'open' and g.creator <> auth.uid()
    and (p_kind is null or g.kind = p_kind)
    and (g.mode = 'async' or coalesce(g.seen_a, g.created_at) > now() - interval '90 seconds')  -- live games show while the creator is waiting
    and not exists (select 1 from public.user_blocks b
                    where (b.blocker = auth.uid() and b.blocked = g.creator) or (b.blocker = g.creator and b.blocked = auth.uid()))
    and (p_q is null or trim(p_q) = '' or p.username ilike '%' || trim(p_q) || '%' or coalesce(p.display_name, '') ilike '%' || trim(p_q) || '%'
         or public.game_label(g.kind) ilike '%' || trim(p_q) || '%' or g.stake::text = trim(p_q))
  order by g.id desc limit 100
$$;

create or replace function public.my_games()
returns table (id bigint, kind text, stake int, mode text, status text, my_turn boolean, deadline timestamptz,
               winner uuid, result text, other_id uuid, other_name text, other_avatar text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select g.id from public.games g where (g.creator = auth.uid() or g.opponent = auth.uid()) and g.status = 'active' loop
    perform public.game_check(r.id);
  end loop;
  return query
    select g.id, g.kind, g.stake, g.mode, g.status, (g.turn = auth.uid()), g.turn_deadline, g.winner, g.result,
           o.id, coalesce(nullif(trim(o.display_name), ''), o.username), o.avatar_url, g.created_at
    from public.games g
    left join public.profiles o on o.id = case when g.creator = auth.uid() then g.opponent else g.creator end
    where (g.creator = auth.uid() or g.opponent = auth.uid())
      and (g.status in ('open', 'active') or (g.status = 'finished' and g.finished_at > now() - interval '7 days'))
    order by case g.status when 'active' then 0 when 'open' then 1 else 2 end, g.id desc limit 60;
end $$;

create or replace function public.join_game(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); g public.games; init jsonb;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  perform 1 from public.profiles where id = uid for update;
  select * into g from public.games where id = p_id for update;
  if not found or g.status <> 'open' then raise exception 'This game is no longer open'; end if;
  if g.creator = uid then raise exception 'You cannot join your own game'; end if;
  if public.points_of(uid) < g.stake then raise exception 'You do not have enough FGP for this bet'; end if;
  if g.kind = 'ludo' then
    init := '{"a":[-1,-1,-1,-1],"b":[-1,-1,-1,-1],"dice":null,"sixes":0,"last":null}'::jsonb;
  else
    raise exception 'This game is coming soon';
  end if;
  insert into public.rewards (user_id, task_id, amount, status) values (uid, 'game:' || p_id || ':stake:' || uid, -g.stake, 'claimed');
  update public.games set opponent = uid, status = 'active', state = init, turn = g.creator, started_at = now(),
         last_move_at = now(), seen_a = now(), seen_b = now(),
         turn_deadline = now() + (case when g.mode = 'live' then interval '120 seconds' else make_interval(hours => g.limit_hours) end)
   where id = p_id;
  perform public.game_notify(g.creator, 'Someone took your ' || public.game_label(g.kind) || ' bet',
                             'Open the game, it is your turn to roll.', p_id, uid);
  return public.game_view(p_id);
end $$;

create or replace function public.get_game(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform public.game_check(p_id);
  return public.game_view(p_id);
end $$;

-- Called every few seconds while someone has a game open. Shows they are there, and returns the game.
create or replace function public.game_ping(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare g public.games; uid uuid := auth.uid();
begin
  select * into g from public.games where id = p_id;
  if not found then raise exception 'Game not found'; end if;
  if uid = g.creator then update public.games set seen_a = now() where id = p_id;
  elsif uid = g.opponent then update public.games set seen_b = now() where id = p_id;
  end if;
  perform public.game_check(p_id);
  return public.game_view(p_id);
end $$;

create or replace function public.resign_game(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare g public.games; uid uuid := auth.uid();
begin
  select * into g from public.games where id = p_id for update;
  if not found or (g.creator <> uid and g.opponent <> uid) then raise exception 'Not your game'; end if;
  if g.status <> 'active' then raise exception 'The game is not running'; end if;
  perform public.game_finish(p_id, case when uid = g.creator then g.opponent else g.creator end, 'Opponent gave up');
  return public.game_view(p_id);
end $$;

-- ---------------------------------------------------------------- Ludo
-- Each token: -1 in the yard, 0..50 on the shared track (0 = its start square), 51..55 home column, 56 home.
create or replace function public.ludo_idx(p_slot text, p_prog int) returns int
language sql immutable as $$
  select case when p_prog between 0 and 50 then ((case p_slot when 'a' then 0 else 26 end) + p_prog) % 52 else null end
$$;

create or replace function public.ludo_roll(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); g public.games; s jsonb; slot text; mine int[]; d int; sixes int; can boolean := false; i int;
  nxt uuid;
begin
  select * into g from public.games where id = p_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.status <> 'active' then raise exception 'The game is not running'; end if;
  if g.turn <> uid then raise exception 'It is not your turn'; end if;
  s := g.state;
  if s->'dice' is not null and s->>'dice' is not null and jsonb_typeof(s->'dice') = 'number' then raise exception 'Move a token first'; end if;
  slot := case when uid = g.creator then 'a' else 'b' end;
  mine := public.jarr(s->slot);
  d := 1 + floor(random() * 6)::int;
  sixes := coalesce((s->>'sixes')::int, 0);
  if d = 6 then sixes := sixes + 1; else sixes := 0; end if;
  nxt := case when uid = g.creator then g.opponent else g.creator end;
  -- three sixes in a row: the turn is lost
  if sixes >= 3 then
    s := jsonb_set(jsonb_set(jsonb_set(s, '{dice}', 'null'::jsonb), '{sixes}', '0'), '{last}', jsonb_build_object('by', slot, 'roll', d, 'note', 'Three sixes in a row'));
    update public.games set state = s, turn = nxt, last_move_at = now(),
      turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end) where id = p_id;
    if g.mode = 'async' then perform public.game_notify(nxt, 'Your turn in Ludo', 'Open the game and roll.', p_id, uid); end if;
    return public.game_view(p_id);
  end if;
  for i in 1..4 loop
    if (mine[i] = -1 and d = 6) or (mine[i] between 0 and 55 and mine[i] + d <= 56) then can := true; end if;
  end loop;
  if not can then
    s := jsonb_set(jsonb_set(jsonb_set(s, '{dice}', 'null'::jsonb), '{sixes}', '0'), '{last}', jsonb_build_object('by', slot, 'roll', d, 'note', 'No move'));
    update public.games set state = s, turn = nxt, last_move_at = now(),
      turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end) where id = p_id;
    if g.mode = 'async' then perform public.game_notify(nxt, 'Your turn in Ludo', 'Open the game and roll.', p_id, uid); end if;
    return public.game_view(p_id);
  end if;
  s := jsonb_set(jsonb_set(s, '{dice}', to_jsonb(d)), '{sixes}', to_jsonb(sixes));
  update public.games set state = s, last_move_at = now(),
    turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end) where id = p_id;
  return public.game_view(p_id);
end $$;

create or replace function public.ludo_move(p_id bigint, p_token int) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); g public.games; s jsonb; slot text; oslot text; mine int[]; theirs int[]; d int;
  t int; np int; idx int; captured boolean := false; j int; extra boolean; nxt uuid; won boolean;
  safe int[] := array[0, 8, 13, 21, 26, 34, 39, 47];
begin
  select * into g from public.games where id = p_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.status <> 'active' then raise exception 'The game is not running'; end if;
  if g.turn <> uid then raise exception 'It is not your turn'; end if;
  s := g.state;
  if jsonb_typeof(s->'dice') <> 'number' then raise exception 'Roll the dice first'; end if;
  if p_token is null or p_token < 0 or p_token > 3 then raise exception 'Pick one of your four tokens'; end if;
  d := (s->>'dice')::int;
  slot := case when uid = g.creator then 'a' else 'b' end;
  oslot := case when slot = 'a' then 'b' else 'a' end;
  mine := public.jarr(s->slot);
  theirs := public.jarr(s->oslot);
  t := mine[p_token + 1];
  if t = -1 then
    if d <> 6 then raise exception 'You need a 6 to leave the yard'; end if;
    np := 0;
  elsif t between 0 and 55 then
    np := t + d;
    if np > 56 then raise exception 'That token needs a smaller number to get home'; end if;
  else
    raise exception 'That token is already home';
  end if;
  -- capture on a normal square
  if np between 0 and 50 then
    idx := public.ludo_idx(slot, np);
    if not (idx = any(safe)) then
      for j in 1..4 loop
        if theirs[j] between 0 and 50 and public.ludo_idx(oslot, theirs[j]) = idx then
          theirs[j] := -1; captured := true;
        end if;
      end loop;
    end if;
  end if;
  mine[p_token + 1] := np;
  won := (mine[1] = 56 and mine[2] = 56 and mine[3] = 56 and mine[4] = 56);
  extra := (d = 6) or captured or (np = 56);
  s := jsonb_set(s, array[slot], to_jsonb(mine));
  s := jsonb_set(s, array[oslot], to_jsonb(theirs));
  s := jsonb_set(s, '{dice}', 'null'::jsonb);
  s := jsonb_set(s, '{last}', jsonb_build_object('by', slot, 'roll', d, 'token', p_token,
        'note', case when captured then 'Captured a token' when np = 56 then 'A token got home' else null end));
  if not extra then s := jsonb_set(s, '{sixes}', '0'); end if;
  nxt := case when extra then uid when uid = g.creator then g.opponent else g.creator end;
  update public.games set state = s, turn = nxt, last_move_at = now(),
    turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end)
  where id = p_id;
  if won then
    perform public.game_finish(p_id, uid, 'All four tokens got home');
  elsif nxt <> uid and g.mode = 'async' then
    perform public.game_notify(nxt, 'Your turn in Ludo', 'Open the game and roll.', p_id, uid);
  end if;
  return public.game_view(p_id);
end $$;

grant execute on function public.create_game(text, int, text, int), public.cancel_game(bigint), public.list_games(text, text),
  public.my_games(), public.join_game(bigint), public.get_game(bigint), public.game_ping(bigint), public.resign_game(bigint),
  public.ludo_roll(bigint), public.ludo_move(bigint, int) to authenticated;
