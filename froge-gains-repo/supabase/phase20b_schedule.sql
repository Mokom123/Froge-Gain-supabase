-- Phase 20b (optional but recommended): check for players who ran out of time or left a live game, every minute.
-- Needs the "Cron" integration turned on (the same one used for chat cleanup).
create extension if not exists pg_cron;
select cron.schedule('game-sweep', '* * * * *', $$ select public.game_sweep() $$);
