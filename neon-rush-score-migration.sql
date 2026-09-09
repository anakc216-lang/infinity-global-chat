-- Persistent global scores for Neon Rush.
-- Run after the existing Supabase migrations.

create table if not exists public.neon_rush_scores (
  player_device_id text primary key check (char_length(player_device_id) between 8 and 180),
  player_name text not null default 'Player' check (char_length(player_name) between 1 and 80),
  total_score bigint not null default 0 check (total_score >= 0),
  updated_at timestamptz not null default now()
);

alter table public.neon_rush_scores
  add column if not exists withdraw_enabled boolean not null default false;

create index if not exists neon_rush_scores_rank_idx
  on public.neon_rush_scores(total_score desc, updated_at asc);

alter table public.neon_rush_scores enable row level security;
revoke all on public.neon_rush_scores from anon, authenticated;

create or replace function public.increment_neon_rush_score(
  p_device_id text,
  p_player_name text,
  p_points integer
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_device_id text := left(btrim(p_device_id), 180);
  v_name text := left(coalesce(nullif(btrim(p_player_name), ''), 'Player'), 80);
  v_points integer := greatest(0, least(coalesce(p_points, 0), 1000));
  v_row public.neon_rush_scores;
begin
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  insert into public.neon_rush_scores(player_device_id, player_name, total_score)
  values (v_device_id, v_name, v_points)
  on conflict (player_device_id) do update
    set player_name = excluded.player_name,
        total_score = public.neon_rush_scores.total_score + excluded.total_score,
        updated_at = now()
  returning * into v_row;
  return jsonb_build_object(
    'player_id', v_row.player_device_id,
    'name', v_row.player_name,
    'score', v_row.total_score,
    'level', floor(v_row.total_score / 100.0)::bigint + 1,
    'fun_savings_cents', floor((floor(v_row.total_score / 100.0)::bigint + 1) / 50.0)::bigint * 100,
    'withdraw_enabled', v_row.withdraw_enabled,
    'updated_at', v_row.updated_at
  );
end;
$$;

drop function if exists public.get_neon_rush_leaderboard(integer);
create function public.get_neon_rush_leaderboard(p_limit integer default 100)
returns table(player_device_id text, player_name text, total_score bigint, withdraw_enabled boolean, updated_at timestamptz, neon_level bigint, fun_savings_cents bigint)
language sql security definer set search_path = public
as $$
  select s.player_device_id, s.player_name, s.total_score, s.withdraw_enabled, s.updated_at,
         floor(s.total_score / 100.0)::bigint + 1,
         floor((floor(s.total_score / 100.0)::bigint + 1) / 50.0)::bigint * 100
  from public.neon_rush_scores s
  order by total_score desc, updated_at asc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

grant execute on function public.increment_neon_rush_score(text, text, integer) to anon, authenticated;
grant execute on function public.get_neon_rush_leaderboard(integer) to anon, authenticated;

notify pgrst, 'reload schema';
