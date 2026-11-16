-- Phase 23: Ludo for 2 to 4 players, automatic move when only one move is possible, message read ticks.
-- Run in Supabase: SQL Editor > New query > paste all > Run. Safe to run more than once. Needs phase20 first.

-- ------------------------------------------------------------ games: seats
alter table public.games add column if not exists max_players int not null default 2;
alter table public.games drop constraint if exists games_max_players_check;
alter table public.games add constraint games_max_players_check check (max_players between 2 and 4);
alter table public.games add column if not exists players uuid[] not null default '{}';
alter table public.games add column if not exists seen jsonb not null default '{}'::jsonb;

update public.games set players = case when opponent is null then array[creator] else array[creator, opponent] end
 where cardinality(players) = 0;
update public.games set seen = jsonb_build_object(creator::text, coalesce(seen_a, now()))
 where seen = '{}'::jsonb and opponent is null;
update public.games set seen = jsonb_build_object(creator::text, coalesce(seen_a, now()), opponent::text, coalesce(seen_b, now()))
 where seen = '{}'::jsonb and opponent is not null;

-- seats: a red (start 0), b yellow (26), c green (13), d blue (39). Turns go a, c, b, d (clockwise).
create or replace function public.ludo_slot(p_players uuid[], p_uid uuid) returns text
language sql immutable as $$
  select case when array_position(p_players, p_uid) is null then null else substr('abcd', array_position(p_players, p_uid), 1) end
$$;

create or replace function public.ludo_idx(p_slot text, p_prog int) returns int
language sql immutable as $$
  select case when p_prog between 0 and 50
    then ((case p_slot when 'a' then 0 when 'b' then 26 when 'c' then 13 else 39 end) + p_prog) % 52 else null end
$$;

-- The next player who is still in the game, after p_cur.
create or replace function public.ludo_next(p_players uuid[], p_state jsonb, p_cur uuid) returns uuid
language plpgsql immutable as $$
declare order_ text[] := array['a', 'c', 'b', 'd']; me text; start int; k int; sl text; pos int;
begin
  me := public.ludo_slot(p_players, p_cur);
  start := array_position(order_, me);
  for k in 1..4 loop
    sl := order_[((start - 1 + k) % 4) + 1];
    pos := position(sl in 'abcd');
    if pos <= cardinality(p_players) and not coalesce(p_state->'out' @> to_jsonb(sl), false) then
      return p_players[pos];
    end if;
  end loop;
  return p_cur;
end $$;

create or replace function public.seen_at(g public.games, p_uid uuid) returns timestamptz
language sql stable as $$
  select coalesce((g.seen ->> p_uid::text)::timestamptz, g.started_at, g.created_at)
$$;

-- ------------------------------------------------------------ finishing
create or replace function public.game_finish(p_id bigint, p_winner uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games; u uuid;
begin
  select * into g from public.games where id = p_id for update;
  if g.status <> 'active' then return; end if;
  update public.games set status = 'finished', winner = p_winner, result = p_reason, turn = null,
         turn_deadline = null, finished_at = now() where id = p_id;
  insert into public.rewards (user_id, task_id, amount, status)
  values (p_winner, 'game:' || p_id || ':win', g.stake * cardinality(g.players), 'claimed') on conflict do nothing;
  perform public.game_notify(p_winner, 'You won ' || public.game_label(g.kind) || '!',
     '+' || (g.stake * (cardinality(g.players) - 1)) || ' FGP (' || p_reason || ')', p_id);
  foreach u in array g.players loop
    if u <> p_winner then
      perform public.game_notify(u, 'You lost ' || public.game_label(g.kind), '-' || g.stake || ' FGP (' || p_reason || ')', p_id);
    end if;
  end loop;
end $$;
revoke execute on function public.game_finish(bigint, uuid, text) from public, anon, authenticated;

create or replace function public.game_refund(p_id bigint, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games; u uuid;
begin
  select * into g from public.games where id = p_id for update;
  if g.status not in ('open', 'active') then return; end if;
  update public.rewards set status = 'cancelled' where task_id like 'game:' || p_id || ':stake:%';
  update public.games set status = 'cancelled', result = p_reason, turn = null, turn_deadline = null, finished_at = now() where id = p_id;
  foreach u in array g.players loop
    if g.status = 'active' or u <> g.creator then
      perform public.game_notify(u, 'Game cancelled', 'Your stake was returned', p_id);
    end if;
  end loop;
end $$;
revoke execute on function public.game_refund(bigint, text) from public, anon, authenticated;

-- A player leaves (or is dropped from) a running game. Their bet stays in the pot.
create or replace function public.game_eliminate(p_id bigint, p_uid uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games; s jsonb; sl text; left_ int; w uuid; nxt uuid; n int;
begin
  select * into g from public.games where id = p_id for update;
  if g.status <> 'active' then return; end if;
  sl := public.ludo_slot(g.players, p_uid);
  if sl is null then return; end if;
  s := g.state;
  if coalesce(s->'out' @> to_jsonb(sl), false) then return; end if;
  s := jsonb_set(s, '{out}', coalesce(s->'out', '[]'::jsonb) || to_jsonb(sl), true);
  left_ := 0;
  for n in 1..cardinality(g.players) loop
    if not (s->'out' @> to_jsonb(substr('abcd', n, 1))) then left_ := left_ + 1; w := g.players[n]; end if;
  end loop;
  update public.games set state = s where id = p_id;
  if left_ = 0 then perform public.game_refund(p_id, 'Everyone left'); return; end if;
  if left_ = 1 then perform public.game_finish(p_id, w, p_reason); return; end if;
  if g.turn = p_uid then
    nxt := public.ludo_next(g.players, s, p_uid);
    s := jsonb_set(jsonb_set(s, '{dice}', 'null'::jsonb), '{sixes}', '0');
    update public.games set state = s, turn = nxt, last_move_at = now(),
      turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end)
     where id = p_id;
  end if;
  perform public.game_notify(p_uid, 'You are out of the game', p_reason, p_id);
end $$;
revoke execute on function public.game_eliminate(bigint, uuid, text) from public, anon, authenticated;

create or replace function public.game_check(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare g public.games; u uuid; n int; gone int; alive int; cutoff timestamptz;
begin
  select * into g from public.games where id = p_id;
  if g.status = 'open' then
    if g.created_at < now() - interval '14 days' then perform public.game_refund(p_id, 'Nobody joined in time'); return; end if;
    if g.mode = 'live' and cardinality(g.players) > 1 then
      if public.seen_at(g, g.creator) < now() - interval '90 seconds' then
        perform public.game_refund(p_id, 'The creator left before the game started'); return;
      end if;
      for n in 2..cardinality(g.players) loop
        u := g.players[n];
        if public.seen_at(g, u) < now() - interval '90 seconds' then
          update public.rewards set status = 'cancelled' where task_id = 'game:' || p_id || ':stake:' || u;
          update public.games set players = array_remove(players, u), opponent = (array_remove(players, u))[2] where id = p_id;
          perform public.game_notify(u, 'You were removed from a game', 'You left the waiting room. Your bet was returned.', p_id);
          exit;
        end if;
      end loop;
    end if;
    return;
  end if;
  if g.status <> 'active' then return; end if;
  if g.mode = 'live' then
    gone := 0; alive := 0;
    for n in 1..cardinality(g.players) loop
      if not coalesce(g.state->'out' @> to_jsonb(substr('abcd', n, 1)), false) then
        alive := alive + 1;
        if public.seen_at(g, g.players[n]) < now() - interval '60 seconds' then gone := gone + 1; end if;
      end if;
    end loop;
    if alive > 0 and gone = alive then perform public.game_refund(p_id, 'All players left'); return; end if;
    for n in 1..cardinality(g.players) loop
      u := g.players[n];
      if not coalesce(g.state->'out' @> to_jsonb(substr('abcd', n, 1)), false)
         and public.seen_at(g, u) < now() - interval '60 seconds' then
        perform public.game_eliminate(p_id, u, 'Opponent left the game');
      end if;
    end loop;
    select * into g from public.games where id = p_id;
    if g.status <> 'active' then return; end if;
  end if;
  if g.turn_deadline is not null and g.turn_deadline < now() and g.turn is not null then
    perform public.game_eliminate(p_id, g.turn, 'Opponent ran out of time');
  end if;
end $$;
revoke execute on function public.game_check(bigint) from public, anon, authenticated;

-- ------------------------------------------------------------ the picture the app draws
create or replace function public.game_view(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare g public.games; uid uuid := auth.uid();
begin
  select * into g from public.games where id = p_id;
  if not found then raise exception 'Game not found'; end if;
  if not (uid = any(g.players)) then raise exception 'This is not your game'; end if;
  return json_build_object(
    'id', g.id, 'kind', g.kind, 'stake', g.stake, 'mode', g.mode, 'limit_hours', g.limit_hours, 'status', g.status,
    'turn', g.turn, 'state', g.state, 'winner', g.winner, 'result', g.result, 'deadline', g.turn_deadline,
    'now', now(), 'me', public.ludo_slot(g.players, uid), 'max_players', g.max_players, 'creator_id', g.creator,
    'players', (select coalesce(json_agg(json_build_object('slot', substr('abcd', t.n::int, 1), 'id', p.id,
                  'name', coalesce(nullif(trim(p.display_name), ''), p.username), 'avatar', p.avatar_url, 'badge', p.badge)
                  order by t.n), '[]'::json)
                from unnest(g.players) with ordinality t(id, n) join public.profiles p on p.id = t.id));
end $$;

-- ------------------------------------------------------------ lobby
drop function if exists public.create_game(text, int, text, int);
create or replace function public.create_game(p_kind text, p_stake int, p_mode text, p_hours int default 24, p_players int default 2) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); gid bigint;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  if p_kind <> 'ludo' then raise exception 'This game is coming soon'; end if;
  if p_stake is null or p_stake < 1 or p_stake > 100000 then raise exception 'Pick a bet between 1 and 100000 FGP'; end if;
  if p_mode not in ('live', 'async') then raise exception 'Bad mode'; end if;
  if p_players is null or p_players < 2 or p_players > 4 then raise exception 'A game has 2 to 4 players'; end if;
  if p_mode = 'async' and p_hours not in (1, 6, 24, 72, 168) then raise exception 'Pick how long each move may take'; end if;
  perform 1 from public.profiles where id = uid for update;
  if (select count(*) from public.games where creator = uid and status = 'open') >= 5 then
    raise exception 'You already have 5 open games. Cancel one first.';
  end if;
  if public.points_of(uid) < p_stake then raise exception 'You do not have enough FGP for this bet'; end if;
  insert into public.games (kind, stake, mode, limit_hours, creator, players, max_players, seen)
  values (p_kind, p_stake, p_mode, case when p_mode = 'async' then p_hours else 24 end, uid, array[uid], p_players,
          jsonb_build_object(uid::text, now())) returning id into gid;
  insert into public.rewards (user_id, task_id, amount, status) values (uid, 'game:' || gid || ':stake:' || uid, -p_stake, 'claimed');
  return gid;
end $$;

drop function if exists public.list_games(text, text);
create or replace function public.list_games(p_kind text default null, p_q text default null)
returns table (id bigint, kind text, stake int, mode text, limit_hours int, created_at timestamptz,
               creator_id uuid, creator_name text, creator_avatar text, creator_badge boolean, max_players int, joined int)
language sql stable security definer set search_path = public as $$
  select g.id, g.kind, g.stake, g.mode, g.limit_hours, g.created_at, p.id,
         coalesce(nullif(trim(p.display_name), ''), p.username), p.avatar_url, p.badge, g.max_players, cardinality(g.players)
  from public.games g join public.profiles p on p.id = g.creator
  where g.status = 'open' and not (auth.uid() = any(g.players)) and cardinality(g.players) < g.max_players
    and (p_kind is null or g.kind = p_kind)
    and (g.mode = 'async' or coalesce((g.seen ->> g.creator::text)::timestamptz, g.created_at) > now() - interval '90 seconds')
    and not exists (select 1 from public.user_blocks b
                    where (b.blocker = auth.uid() and b.blocked = g.creator) or (b.blocker = g.creator and b.blocked = auth.uid()))
    and (p_q is null or trim(p_q) = '' or p.username ilike '%' || trim(p_q) || '%' or coalesce(p.display_name, '') ilike '%' || trim(p_q) || '%'
         or public.game_label(g.kind) ilike '%' || trim(p_q) || '%' or g.stake::text = trim(p_q))
  order by g.id desc limit 100
$$;

drop function if exists public.my_games();
create or replace function public.my_games()
returns table (id bigint, kind text, stake int, mode text, status text, my_turn boolean, deadline timestamptz,
               winner uuid, result text, other_id uuid, other_name text, other_avatar text, created_at timestamptz,
               max_players int, joined int)
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select g.id from public.games g where auth.uid() = any(g.players) and g.status in ('active', 'open') loop
    perform public.game_check(r.id);
  end loop;
  return query
    select g.id, g.kind, g.stake, g.mode, g.status, (g.turn = auth.uid()), g.turn_deadline, g.winner, g.result,
           o.id, coalesce(nullif(trim(o.display_name), ''), o.username), o.avatar_url, g.created_at, g.max_players, cardinality(g.players)
    from public.games g
    left join public.profiles o on o.id = (select x from unnest(g.players) x where x <> auth.uid() limit 1)
    where auth.uid() = any(g.players)
      and (g.status in ('open', 'active') or (g.status = 'finished' and g.finished_at > now() - interval '7 days'))
    order by case g.status when 'active' then 0 when 'open' then 1 else 2 end, g.id desc limit 60;
end $$;

create or replace function public.join_game(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); g public.games; init jsonb; np uuid[]; i int; full boolean; u uuid;
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if not public.is_active_user() then raise exception 'Your account is not active'; end if;
  perform 1 from public.profiles where id = uid for update;
  select * into g from public.games where id = p_id for update;
  if not found or g.status <> 'open' then raise exception 'This game is no longer open'; end if;
  if uid = any(g.players) then raise exception 'You are already in this game'; end if;
  if cardinality(g.players) >= g.max_players then raise exception 'This game is full'; end if;
  if g.kind <> 'ludo' then raise exception 'This game is coming soon'; end if;
  if public.points_of(uid) < g.stake then raise exception 'You do not have enough FGP for this bet'; end if;
  insert into public.rewards (user_id, task_id, amount, status) values (uid, 'game:' || p_id || ':stake:' || uid, -g.stake, 'claimed');
  np := g.players || uid;
  full := cardinality(np) = g.max_players;
  if full then
    init := '{"dice":null,"sixes":0,"last":null,"out":[]}'::jsonb;
    for i in 1..cardinality(np) loop
      init := jsonb_set(init, array[substr('abcd', i, 1)], '[-1,-1,-1,-1]'::jsonb, true);
    end loop;
    update public.games set players = np, opponent = np[2], status = 'active', state = init, turn = g.creator, started_at = now(),
           last_move_at = now(), seen = g.seen || jsonb_build_object(uid::text, now(), g.creator::text, now()),
           turn_deadline = now() + (case when g.mode = 'live' then interval '120 seconds' else make_interval(hours => g.limit_hours) end)
     where id = p_id;
    perform public.game_notify(g.creator, 'Your ' || public.game_label(g.kind) || ' game is full',
                               'Everyone is in. Open the game and roll first.', p_id, uid);
    foreach u in array np loop
      if u <> g.creator and u <> uid then
        perform public.game_notify(u, 'Your ' || public.game_label(g.kind) || ' game started', 'Everyone is in. The game has begun.', p_id);
      end if;
    end loop;
  else
    update public.games set players = np, opponent = np[2], seen = g.seen || jsonb_build_object(uid::text, now()) where id = p_id;
    perform public.game_notify(g.creator, 'Someone joined your ' || public.game_label(g.kind) || ' game',
                               cardinality(np) || ' of ' || g.max_players || ' players are in.', p_id, uid);
  end if;
  return public.game_view(p_id);
end $$;

-- A joined player changes their mind before the game starts: the bet is returned.
create or replace function public.leave_game(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); g public.games;
begin
  select * into g from public.games where id = p_id for update;
  if not found or not (uid = any(g.players)) then raise exception 'Not your game'; end if;
  if g.status <> 'open' then raise exception 'This game already started'; end if;
  if uid = g.creator then raise exception 'Use cancel to close your own game'; end if;
  update public.rewards set status = 'cancelled' where task_id = 'game:' || p_id || ':stake:' || uid;
  update public.games set players = array_remove(players, uid), opponent = (array_remove(players, uid))[2] where id = p_id;
end $$;

create or replace function public.game_ping(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare g public.games; uid uuid := auth.uid();
begin
  select * into g from public.games where id = p_id;
  if not found then raise exception 'Game not found'; end if;
  if uid = any(g.players) then
    update public.games set seen = seen || jsonb_build_object(uid::text, now()) where id = p_id;
  end if;
  perform public.game_check(p_id);
  return public.game_view(p_id);
end $$;

create or replace function public.resign_game(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare g public.games; uid uuid := auth.uid();
begin
  select * into g from public.games where id = p_id for update;
  if not found or not (uid = any(g.players)) then raise exception 'Not your game'; end if;
  if g.status <> 'active' then raise exception 'The game is not running'; end if;
  perform public.game_eliminate(p_id, uid, 'Opponent gave up');
  return public.game_view(p_id);
end $$;

-- ------------------------------------------------------------ Ludo
create or replace function public.ludo_roll(p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); g public.games; s jsonb; slot text; mine int[]; d int; sixes int; i int; nxt uuid;
  tok int := -1; distinct_moves int[] := '{}'; v int;
begin
  select * into g from public.games where id = p_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.status <> 'active' then raise exception 'The game is not running'; end if;
  if g.turn <> uid then raise exception 'It is not your turn'; end if;
  s := g.state;
  if jsonb_typeof(s->'dice') = 'number' then raise exception 'Move a token first'; end if;
  slot := public.ludo_slot(g.players, uid);
  mine := public.jarr(s->slot);
  d := 1 + floor(random() * 6)::int;
  sixes := coalesce((s->>'sixes')::int, 0);
  if d = 6 then sixes := sixes + 1; else sixes := 0; end if;
  nxt := public.ludo_next(g.players, s, uid);
  if sixes >= 3 then
    s := jsonb_set(jsonb_set(jsonb_set(s, '{dice}', 'null'::jsonb), '{sixes}', '0'), '{last}', jsonb_build_object('by', slot, 'roll', d, 'note', 'Three sixes in a row'));
    update public.games set state = s, turn = nxt, last_move_at = now(),
      turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end) where id = p_id;
    if g.mode = 'async' then perform public.game_notify(nxt, 'Your turn in Ludo', 'Open the game and roll.', p_id, uid); end if;
    return public.game_view(p_id);
  end if;
  -- which tokens can move? (tokens in the yard, or on the same square, count as one choice)
  for i in 1..4 loop
    v := mine[i];
    if (v = -1 and d = 6) or (v between 0 and 55 and v + d <= 56) then
      if not (v = any(distinct_moves)) then distinct_moves := distinct_moves || v; end if;
      if tok = -1 then tok := i - 1; end if;
    end if;
  end loop;
  if cardinality(distinct_moves) = 0 then
    s := jsonb_set(jsonb_set(jsonb_set(s, '{dice}', 'null'::jsonb), '{sixes}', '0'), '{last}', jsonb_build_object('by', slot, 'roll', d, 'note', 'No move'));
    update public.games set state = s, turn = nxt, last_move_at = now(),
      turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end) where id = p_id;
    if g.mode = 'async' then perform public.game_notify(nxt, 'Your turn in Ludo', 'Open the game and roll.', p_id, uid); end if;
    return public.game_view(p_id);
  end if;
  s := jsonb_set(jsonb_set(s, '{dice}', to_jsonb(d)), '{sixes}', to_jsonb(sixes));
  update public.games set state = s, last_move_at = now(),
    turn_deadline = now() + (case when mode = 'live' then interval '120 seconds' else make_interval(hours => limit_hours) end) where id = p_id;
  -- only one possible move: play it automatically
  if cardinality(distinct_moves) = 1 then
    return public.ludo_move(p_id, tok);
  end if;
  return public.game_view(p_id);
end $$;

create or replace function public.ludo_move(p_id bigint, p_token int) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); g public.games; s jsonb; slot text; oslot text; mine int[]; theirs int[]; d int;
  t int; np int; idx int; captured boolean := false; j int; k int; extra boolean; nxt uuid; won boolean;
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
  slot := public.ludo_slot(g.players, uid);
  mine := public.jarr(s->slot);
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
  if np between 0 and 50 then
    idx := public.ludo_idx(slot, np);
    if not (idx = any(safe)) then
      for k in 1..cardinality(g.players) loop
        oslot := substr('abcd', k, 1);
        if oslot <> slot then
          theirs := public.jarr(s->oslot);
          for j in 1..4 loop
            if theirs[j] between 0 and 50 and public.ludo_idx(oslot, theirs[j]) = idx then
              theirs[j] := -1; captured := true;
            end if;
          end loop;
          s := jsonb_set(s, array[oslot], to_jsonb(theirs));
        end if;
      end loop;
    end if;
  end if;
  mine[p_token + 1] := np;
  won := (mine[1] = 56 and mine[2] = 56 and mine[3] = 56 and mine[4] = 56);
  extra := (d = 6) or captured or (np = 56);
  s := jsonb_set(s, array[slot], to_jsonb(mine));
  s := jsonb_set(s, '{dice}', 'null'::jsonb);
  s := jsonb_set(s, '{last}', jsonb_build_object('by', slot, 'roll', d, 'token', p_token,
        'note', case when captured then 'Captured a token' when np = 56 then 'A token got home' else null end));
  if not extra then s := jsonb_set(s, '{sixes}', '0'); end if;
  nxt := case when extra then uid else public.ludo_next(g.players, s, uid) end;
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

grant execute on function public.create_game(text, int, text, int, int), public.list_games(text, text), public.my_games(),
  public.join_game(bigint), public.leave_game(bigint), public.game_ping(bigint), public.resign_game(bigint),
  public.ludo_roll(bigint), public.ludo_move(bigint, int) to authenticated;

-- ------------------------------------------------------------ message ticks
-- one tick = sent, two ticks = reached the other phone, two blue ticks = read.
alter table public.messages add column if not exists delivered_at timestamptz;

create or replace function public.mark_read(p_peer uuid) returns void
language sql security definer set search_path = public as $$
  update public.messages set read_at = now(), delivered_at = coalesce(delivered_at, now())
   where recipient_id = auth.uid() and sender_id = p_peer and read_at is null
$$;

-- The app asks this every minute and on opening, so asking also counts as "arrived on the phone".
drop function if exists public.chat_unread_count();
create or replace function public.chat_unread_count() returns int
language plpgsql volatile security definer set search_path = public as $$
begin
  update public.messages set delivered_at = now() where recipient_id = auth.uid() and delivered_at is null;
  return (select count(*)::int from public.messages where recipient_id = auth.uid() and read_at is null);
end $$;
grant execute on function public.chat_unread_count(), public.mark_read(uuid) to authenticated;
