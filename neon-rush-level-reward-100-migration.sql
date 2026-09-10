-- Set Neon Rush virtual value to RM100 for every 20 levels, cumulatively without a limit.
-- Run this after the existing Neon Rush migrations.
-- Existing scores and withdrawal history are preserved. Only newly calculated values change.

create or replace function public.neon_rush_reward_cents(p_level bigint)
returns bigint language sql immutable
as $$
  select floor(greatest(coalesce(p_level, 0), 0) / 20.0)::bigint * 10000;
$$;

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
    'fun_savings_cents', public.neon_rush_reward_cents(floor(v_row.total_score / 100.0)::bigint + 1),
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
         public.neon_rush_reward_cents(floor(s.total_score / 100.0)::bigint + 1)
  from public.neon_rush_scores s
  order by total_score desc, updated_at asc
  limit greatest(1, least(coalesce(p_limit, 100), 500));
$$;

create or replace function public.get_neon_rush_withdrawal_status(p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_device_id text := left(btrim(p_device_id), 180);
  v_user_id uuid := auth.uid();
  v_total_installs bigint;
  v_target bigint;
  v_enabled boolean;
  v_production_enabled boolean;
  v_score bigint := 0;
  v_level bigint := 1;
  v_fun_savings_cents bigint := 0;
  v_history jsonb;
begin
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  select count(*) into v_total_installs from public.app_installations;
  select global_install_target, production_enabled into v_target, v_production_enabled
  from public.neon_rush_withdrawal_config where id = true;
  select coalesce(a.enabled, false) into v_enabled
  from public.neon_rush_withdrawal_access a
  where a.player_device_id = v_device_id and (a.user_id is null or a.user_id = v_user_id);
  select total_score into v_score from public.neon_rush_scores where player_device_id = v_device_id;
  v_level := floor(coalesce(v_score, 0) / 100.0)::bigint + 1;
  v_fun_savings_cents := public.neon_rush_reward_cents(v_level);
  select coalesce(jsonb_agg(row_to_json(h) order by h.created_at desc), '[]'::jsonb) into v_history
  from (
    select id, amount_cents, level_snapshot, score_snapshot,
           fun_savings_cents_snapshot, payment_method, status,
           rejection_reason, created_at
    from public.neon_rush_game_withdrawals
    where player_device_id = v_device_id
      and (owner_user_id is null or owner_user_id = v_user_id)
    order by created_at desc limit 50
  ) h;
  return jsonb_build_object(
    'score', coalesce(v_score, 0),
    'level', v_level,
    'fun_savings_cents', v_fun_savings_cents,
    'available', coalesce(v_production_enabled, false)
      and coalesce(v_enabled, false)
      and v_total_installs >= coalesce(v_target, 1),
    'locked', not (coalesce(v_production_enabled, false)
      and coalesce(v_enabled, false)
      and v_total_installs >= coalesce(v_target, 1)),
    'history', v_history
  );
end;
$$;

create or replace function public.create_neon_rush_game_withdrawal(
  p_device_id text, p_payment_method text, p_payment_account text,
  p_request_key uuid
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_device_id text := left(btrim(p_device_id), 180);
  v_user_id uuid := auth.uid();
  v_score public.neon_rush_scores;
  v_existing public.neon_rush_game_withdrawals;
  v_total_installs bigint;
  v_target bigint;
  v_access boolean;
  v_production_enabled boolean;
  v_approved_bank_account text;
  v_level bigint;
  v_amount bigint;
begin
  if v_user_id is null then raise exception 'AUTHENTICATION_REQUIRED'; end if;
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  if p_payment_method not in ('bank', 'no_bank') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  select approved_bank_account into v_approved_bank_account
  from public.neon_rush_withdrawal_access
  where player_device_id = v_device_id and (user_id is null or user_id = v_user_id);
  if p_payment_method = 'bank' and char_length(trim(coalesce(v_approved_bank_account, ''))) not between 3 and 160 then raise exception 'BANK_DETAILS_NOT_APPROVED'; end if;
  if p_payment_method = 'no_bank' and nullif(trim(coalesce(p_payment_account, '')), '') is not null then raise exception 'INVALID_BANK_DETAILS'; end if;
  select * into v_existing from public.neon_rush_game_withdrawals where player_device_id = v_device_id and request_key = p_request_key;
  if v_existing.id is not null then return jsonb_build_object('success', true, 'id', v_existing.id, 'status', v_existing.status); end if;
  select * into v_score from public.neon_rush_scores where player_device_id = v_device_id;
  if v_score.player_device_id is null then raise exception 'GAME_PLAYER_NOT_FOUND'; end if;
  select count(*) into v_total_installs from public.app_installations;
  select global_install_target, production_enabled into v_target, v_production_enabled from public.neon_rush_withdrawal_config where id = true;
  select coalesce(a.enabled, false) into v_access from public.neon_rush_withdrawal_access a where a.player_device_id = v_device_id and (a.user_id is null or a.user_id = v_user_id);
  if not coalesce(v_production_enabled, false) or not coalesce(v_access, false) or v_total_installs < coalesce(v_target, 1) then raise exception 'GAME_WITHDRAWAL_UNAVAILABLE'; end if;
  v_level := floor(v_score.total_score / 100.0)::bigint + 1;
  v_amount := public.neon_rush_reward_cents(v_level);
  if v_amount < 10000 then raise exception 'GAME_REWARD_NOT_REACHED'; end if;
  insert into public.neon_rush_game_withdrawals(
    player_device_id, owner_user_id, amount_cents, level_snapshot, score_snapshot,
    fun_savings_cents_snapshot, payment_method, payment_account, status, request_key
  ) values (
    v_device_id, v_user_id, v_amount, v_level, v_score.total_score,
    v_amount, p_payment_method,
    case when p_payment_method = 'bank' then v_approved_bank_account else null end,
    'pending', p_request_key
  ) returning * into v_existing;
  return jsonb_build_object('success', true, 'id', v_existing.id, 'status', v_existing.status, 'amount_cents', v_existing.amount_cents);
end;
$$;

grant execute on function public.increment_neon_rush_score(text, text, integer), public.get_neon_rush_leaderboard(integer), public.get_neon_rush_withdrawal_status(text), public.create_neon_rush_game_withdrawal(text, text, text, uuid) to anon, authenticated;

do $$
begin
  if public.neon_rush_reward_cents(20) <> 10000
    or public.neon_rush_reward_cents(40) <> 20000
    or public.neon_rush_reward_cents(60) <> 30000
    or public.neon_rush_reward_cents(80) <> 40000
    or public.neon_rush_reward_cents(100) <> 50000 then
    raise exception 'NEON_RUSH_REWARD_MIGRATION_VERIFICATION_FAILED';
  end if;
end;
$$;

notify pgrst, 'reload schema';