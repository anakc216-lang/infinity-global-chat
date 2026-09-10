-- Neon Rush game earnings withdrawal, separate from all referral withdrawals.
-- Run after app-install-rating-migration.sql and neon-rush-score-migration.sql.

create table if not exists public.neon_rush_withdrawal_config (
  id boolean primary key default true check (id),
  global_install_target bigint not null default 1000000 check (global_install_target > 0),
  production_enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

insert into public.neon_rush_withdrawal_config (id)
values (true)
on conflict (id) do nothing;

create table if not exists public.neon_rush_withdrawal_access (
  player_device_id text primary key check (char_length(player_device_id) between 8 and 180),
  user_id uuid references auth.users(id) on delete set null,
  approved_bank_account text,
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

alter table public.neon_rush_withdrawal_access
  add column if not exists approved_bank_account text;

create table if not exists public.neon_rush_game_withdrawals (
  id uuid primary key default gen_random_uuid(),
  player_device_id text not null check (char_length(player_device_id) between 8 and 180),
  owner_user_id uuid references auth.users(id) on delete set null,
  amount_cents bigint not null check (amount_cents > 0),
  level_snapshot bigint not null check (level_snapshot >= 1),
  score_snapshot bigint not null check (score_snapshot >= 0),
  fun_savings_cents_snapshot bigint not null check (fun_savings_cents_snapshot >= 0),
  payment_method text not null check (payment_method in ('bank', 'no_bank')),
  payment_account text,
  status text not null default 'locked' check (status in ('locked', 'pending', 'processing', 'paid', 'rejected')),
  rejection_reason text,
  request_key uuid not null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  unique (player_device_id, request_key),
  check ((payment_method = 'bank' and char_length(coalesce(payment_account, '')) between 3 and 160) or (payment_method = 'no_bank' and payment_account is null))
);

create index if not exists neon_rush_game_withdrawals_owner_idx
  on public.neon_rush_game_withdrawals(player_device_id, created_at desc);

alter table public.neon_rush_withdrawal_config enable row level security;
alter table public.neon_rush_withdrawal_access enable row level security;
alter table public.neon_rush_game_withdrawals enable row level security;
revoke all on public.neon_rush_withdrawal_config, public.neon_rush_withdrawal_access, public.neon_rush_game_withdrawals from anon, authenticated;
grant select on public.neon_rush_game_withdrawals to authenticated;

drop policy if exists "Neon Rush withdrawal owner read" on public.neon_rush_game_withdrawals;
create policy "Neon Rush withdrawal owner read"
  on public.neon_rush_game_withdrawals for select to authenticated
  using (owner_user_id = auth.uid());

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
  v_fun_savings_cents := floor(v_level / 20.0)::bigint * 10000;
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
  v_amount := floor(v_level / 20.0)::bigint * 10000;
  if v_amount < 100 then raise exception 'GAME_REWARD_NOT_REACHED'; end if;
  insert into public.neon_rush_game_withdrawals(
    player_device_id, owner_user_id, amount_cents, level_snapshot, score_snapshot,
    fun_savings_cents_snapshot, payment_method, payment_account, status, request_key
  ) values (
    v_device_id, v_user_id, v_amount, v_level, v_score.total_score,
    floor(v_level / 20.0)::bigint * 10000, p_payment_method,
    case when p_payment_method = 'bank' then v_approved_bank_account else null end,
    'pending', p_request_key
  ) returning * into v_existing;
  return jsonb_build_object('success', true, 'id', v_existing.id, 'status', v_existing.status, 'amount_cents', v_existing.amount_cents);
end;
$$;

create or replace function public.admin_list_neon_rush_game_withdrawals()
returns setof public.neon_rush_game_withdrawals language sql security definer set search_path = public
as $$
  select w.* from public.neon_rush_game_withdrawals w
  where public.public_user_referral_is_admin()
  order by w.created_at asc;
$$;

create or replace function public.admin_update_neon_rush_game_withdrawal(
  p_withdrawal_id uuid, p_status text, p_rejection_reason text default null
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_row public.neon_rush_game_withdrawals;
begin
  if not public.public_user_referral_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if p_status not in ('processing', 'paid', 'rejected') then raise exception 'INVALID_WITHDRAWAL_STATUS'; end if;
  if p_status = 'rejected' and nullif(trim(p_rejection_reason), '') is null then raise exception 'REJECTION_REASON_REQUIRED'; end if;
  update public.neon_rush_game_withdrawals
  set status = p_status,
      rejection_reason = case when p_status = 'rejected' then trim(p_rejection_reason) else null end,
      reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_withdrawal_id and status in ('pending', 'processing')
  returning * into v_row;
  if v_row.id is null then raise exception 'WITHDRAWAL_NOT_FOUND_OR_CLOSED'; end if;
  return jsonb_build_object('success', true, 'status', v_row.status);
end;
$$;

create or replace function public.admin_set_neon_rush_withdrawal_config(
  p_global_install_target bigint, p_production_enabled boolean
)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.public_user_referral_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if p_global_install_target is null or p_global_install_target <= 0 then raise exception 'INVALID_INSTALL_TARGET'; end if;
  update public.neon_rush_withdrawal_config
  set global_install_target = p_global_install_target,
      production_enabled = coalesce(p_production_enabled, false),
      updated_at = now(), updated_by = auth.uid()
  where id = true;
  return jsonb_build_object('success', true, 'production_enabled', coalesce(p_production_enabled, false));
end;
$$;

drop function if exists public.admin_set_neon_rush_withdrawal_access(text, uuid, boolean);
create or replace function public.admin_set_neon_rush_withdrawal_access(
  p_device_id text, p_user_id uuid, p_enabled boolean, p_approved_bank_account text default null
)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.public_user_referral_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if char_length(trim(coalesce(p_device_id, ''))) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  if p_approved_bank_account is not null and char_length(trim(p_approved_bank_account)) not between 3 and 160 then raise exception 'INVALID_BANK_DETAILS'; end if;
  insert into public.neon_rush_withdrawal_access(player_device_id, user_id, approved_bank_account, enabled, updated_at, updated_by)
  values (left(trim(p_device_id), 180), p_user_id, nullif(trim(p_approved_bank_account), ''), coalesce(p_enabled, false), now(), auth.uid())
  on conflict (player_device_id) do update set user_id = excluded.user_id, approved_bank_account = excluded.approved_bank_account, enabled = excluded.enabled, updated_at = now(), updated_by = auth.uid();
  return jsonb_build_object('success', true, 'enabled', coalesce(p_enabled, false));
end;
$$;

revoke all on function public.get_neon_rush_withdrawal_status(text), public.create_neon_rush_game_withdrawal(text, text, text, uuid) from public;
grant execute on function public.get_neon_rush_withdrawal_status(text), public.create_neon_rush_game_withdrawal(text, text, text, uuid) to anon, authenticated;
revoke all on function public.admin_list_neon_rush_game_withdrawals(), public.admin_update_neon_rush_game_withdrawal(uuid, text, text), public.admin_set_neon_rush_withdrawal_config(bigint, boolean), public.admin_set_neon_rush_withdrawal_access(text, uuid, boolean, text) from public;
grant execute on function public.admin_list_neon_rush_game_withdrawals(), public.admin_update_neon_rush_game_withdrawal(uuid, text, text), public.admin_set_neon_rush_withdrawal_config(bigint, boolean), public.admin_set_neon_rush_withdrawal_access(text, uuid, boolean, text) to authenticated;

notify pgrst, 'reload schema';
