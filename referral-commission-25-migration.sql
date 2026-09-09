-- Referral commission patch: every 25 verified referrals earns RM5.00.
-- Run after public-user-referral-migration.sql.

create table if not exists public.public_user_referral_payment_ledger (
  id uuid primary key default gen_random_uuid(),
  withdrawal_id uuid not null unique references public.public_user_referral_withdrawals(id) on delete restrict,
  owner_device_id text not null,
  amount_cents integer not null check (amount_cents > 0),
  entry_type text not null default 'withdrawal_payment' check (entry_type = 'withdrawal_payment'),
  created_at timestamptz not null default now()
);

create index if not exists public_user_referral_payment_ledger_owner_idx
  on public.public_user_referral_payment_ledger(owner_device_id, created_at desc);

alter table public.public_user_referral_payment_ledger enable row level security;
revoke all on public.public_user_referral_payment_ledger from anon, authenticated;
grant select on public.public_user_referral_payment_ledger to authenticated;

drop policy if exists "Public user referral payment owner read" on public.public_user_referral_payment_ledger;
create policy "Public user referral payment owner read"
  on public.public_user_referral_payment_ledger for select to authenticated
  using (owner_device_id = left(btrim(current_setting('request.headers', true)::jsonb ->> 'x-device-id'), 180)
    or public.public_user_referral_is_admin());

-- Preserve already-paid withdrawals when moving from the old derived formula.
insert into public.public_user_referral_payment_ledger(withdrawal_id, owner_device_id, amount_cents)
select id, owner_device_id, amount_cents
from public.public_user_referral_withdrawals
where status = 'paid'
on conflict (withdrawal_id) do nothing;

create or replace function public.claim_public_user_referral(p_referral_code text, p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_code text := upper(btrim(p_referral_code));
  v_device_id text := left(btrim(p_device_id), 180);
  v_user_id uuid := auth.uid();
  v_link public.public_user_referral_links;
  v_conversion public.public_user_referral_conversions;
  v_count integer;
  v_milestone_reward integer;
begin
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  if v_code !~ '^[A-Z0-9]{6}$' or char_length(v_device_id) < 8 then
    return jsonb_build_object('success', false, 'reason', 'INVALID_REFERRAL');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_device_id, 0));
  select * into v_link from public.public_user_referral_links where referral_code = v_code for update;
  if v_link.id is null then return jsonb_build_object('success', false, 'reason', 'INVALID_REFERRAL'); end if;
  if v_link.owner_user_id = v_user_id or v_link.owner_device_id = v_device_id then
    return jsonb_build_object('success', false, 'reason', 'SELF_REFERRAL');
  end if;
  insert into public.public_user_referral_conversions(referral_link_id, owner_user_id, referred_user_id, referred_device_id)
  values (v_link.id, v_link.owner_user_id, v_user_id, v_device_id)
  on conflict (referred_device_id) do nothing returning * into v_conversion;
  if v_conversion.id is null then return jsonb_build_object('success', false, 'reason', 'ALREADY_VERIFIED'); end if;
  select count(*)::integer into v_count
  from public.public_user_referral_conversions where referral_link_id = v_link.id;
  v_milestone_reward := (floor(v_count / 25.0)::integer - floor((v_count - 1) / 25.0)::integer) * 500;
  return jsonb_build_object('success', true, 'reward_cents', v_milestone_reward);
exception when unique_violation then
  return jsonb_build_object('success', false, 'reason', 'ALREADY_VERIFIED');
end;
$$;

create or replace function public.get_public_user_referral_dashboard(p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_device_id text := left(btrim(p_device_id), 180);
  v_user_id uuid := auth.uid();
  v_link public.public_user_referral_links;
  v_count integer;
  v_earned integer;
  v_paid integer;
  v_pending integer;
  v_balance integer;
  v_claimable integer;
  v_target integer;
  v_history jsonb;
begin
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  perform public.get_or_create_public_user_referral_link(v_device_id);
  select * into v_link from public.public_user_referral_links where owner_device_id = v_device_id;
  if v_link.id is null or (v_user_id is not null and v_link.owner_user_id is not null and v_link.owner_user_id <> v_user_id) then raise exception 'REFERRAL_LINK_OWNER_MISMATCH'; end if;
  select count(*)::integer into v_count from public.public_user_referral_conversions where referral_link_id = v_link.id;
  v_earned := floor(v_count / 25.0)::integer * 500;
  select coalesce(sum(amount_cents), 0)::integer into v_paid from public.public_user_referral_payment_ledger where owner_device_id = v_device_id;
  select coalesce(sum(amount_cents), 0)::integer into v_pending from public.public_user_referral_withdrawals where owner_device_id = v_device_id and status in ('pending', 'processing');
  v_balance := greatest(0, v_earned - v_paid);
  v_claimable := greatest(0, v_balance - v_pending);
  v_target := case when v_count = 0 then 25 when v_count % 25 = 0 then v_count else (floor(v_count / 25.0)::integer + 1) * 25 end;
  select coalesce(jsonb_agg(row_to_json(h) order by h.created_at desc), '[]'::jsonb) into v_history
  from (select id, amount_cents, payment_method, status, rejection_reason, created_at from public.public_user_referral_withdrawals where owner_device_id = v_device_id order by created_at desc limit 20) h;
  return jsonb_build_object('referral_code', v_link.referral_code, 'referral_number', v_link.referral_number, 'referral_link', 'https://infinity-global-chat.onrender.com/?ref=' || v_link.referral_code, 'referral_count', v_count, 'earned_cents', v_earned, 'paid_cents', v_paid, 'balance_cents', v_balance, 'claimable_cents', v_claimable, 'target_count', v_target, 'target_amount_cents', 500, 'history', v_history);
end;
$$;

create or replace function public.create_public_user_referral_withdrawal(p_payment_method text, p_payment_account text, p_request_key uuid, p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_device_id text := left(btrim(p_device_id), 180);
  v_link public.public_user_referral_links;
  v_count integer;
  v_earned integer;
  v_paid integer;
  v_pending integer;
  v_claimable integer;
  v_existing public.public_user_referral_withdrawals;
  v_new public.public_user_referral_withdrawals;
begin
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_device_id, 0));
  select * into v_link from public.public_user_referral_links where owner_device_id = v_device_id for update;
  if v_link.id is null or (v_user_id is not null and v_link.owner_user_id is not null and v_link.owner_user_id <> v_user_id) then raise exception 'REFERRAL_LINK_OWNER_MISMATCH'; end if;
  select * into v_existing from public.public_user_referral_withdrawals where owner_device_id = v_device_id and request_key = p_request_key;
  if v_existing.id is not null then return jsonb_build_object('success', true, 'id', v_existing.id, 'status', v_existing.status, 'amount_cents', v_existing.amount_cents); end if;
  select count(*)::integer into v_count from public.public_user_referral_conversions where referral_link_id = v_link.id;
  v_earned := floor(v_count / 25.0)::integer * 500;
  select coalesce(sum(amount_cents), 0)::integer into v_paid from public.public_user_referral_payment_ledger where owner_device_id = v_device_id;
  select coalesce(sum(amount_cents), 0)::integer into v_pending from public.public_user_referral_withdrawals where owner_device_id = v_device_id and status in ('pending', 'processing');
  v_claimable := greatest(0, v_earned - v_paid - v_pending);
  if v_claimable < 500 then raise exception 'MINIMUM_WITHDRAWAL_NOT_REACHED'; end if;
  if p_payment_method not in ('bank_transfer', 'ewallet') or char_length(trim(p_payment_account)) not between 3 and 160 then raise exception 'INVALID_PAYMENT_DETAILS'; end if;
  insert into public.public_user_referral_withdrawals(owner_user_id, owner_device_id, amount_cents, referral_count_snapshot, payment_method, payment_account, request_key)
  values (v_user_id, v_device_id, v_claimable, v_count, p_payment_method, trim(p_payment_account), p_request_key) returning * into v_new;
  return jsonb_build_object('success', true, 'id', v_new.id, 'status', v_new.status, 'amount_cents', v_new.amount_cents);
end;
$$;

create or replace function public.admin_update_public_user_referral_withdrawal(p_withdrawal_id uuid, p_status text, p_rejection_reason text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_row public.public_user_referral_withdrawals;
begin
  if not public.public_user_referral_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if p_status not in ('processing', 'paid', 'rejected') then raise exception 'INVALID_WITHDRAWAL_STATUS'; end if;
  if p_status = 'rejected' and nullif(trim(p_rejection_reason), '') is null then raise exception 'REJECTION_REASON_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_withdrawal_id::text, 0));
  update public.public_user_referral_withdrawals
  set status = p_status, rejection_reason = case when p_status = 'rejected' then trim(p_rejection_reason) else null end, reviewed_at = now(), reviewed_by = auth.uid()
  where id = p_withdrawal_id and status in ('pending', 'processing') returning * into v_row;
  if v_row.id is null then raise exception 'WITHDRAWAL_NOT_FOUND_OR_CLOSED'; end if;
  if p_status = 'paid' then
    insert into public.public_user_referral_payment_ledger(withdrawal_id, owner_device_id, amount_cents)
    values (v_row.id, v_row.owner_device_id, v_row.amount_cents);
  end if;
  return jsonb_build_object('success', true, 'status', v_row.status);
end;
$$;

notify pgrst, 'reload schema';