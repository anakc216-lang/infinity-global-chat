-- Earnings formula patch: 50 verified users = RM10.00.
-- Run after earnings-referral-withdrawal-migration.sql.

alter table public.user_earnings_ledger
  drop constraint if exists user_earnings_ledger_amount_cents_check;
alter table public.user_earnings_ledger
  add constraint user_earnings_ledger_amount_cents_check check (amount_cents = 20);

alter table public.user_withdrawal_requests
  drop constraint if exists user_withdrawal_requests_referral_count_snapshot_check;
alter table public.user_withdrawal_requests
  add constraint user_withdrawal_requests_referral_count_snapshot_check check (referral_count_snapshot >= 50);

update public.user_earnings_ledger
set amount_cents = 20
where entry_type = 'referral_reward' and currency = 'MYR' and amount_cents = 10;

create or replace function public.claim_user_referral(p_referral_code text, p_device_id text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare owner_id uuid; code_id uuid; verified_id uuid;
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return jsonb_build_object('success', false, 'reason', 'AUTHENTICATED_ACCOUNT_REQUIRED');
  end if;
  select id, owner_user_id into code_id, owner_id from public.user_referral_codes where referral_code = trim(p_referral_code);
  if code_id is null then return jsonb_build_object('success', false, 'reason', 'INVALID_REFERRAL'); end if;
  if owner_id = auth.uid() then return jsonb_build_object('success', false, 'reason', 'SELF_REFERRAL'); end if;
  insert into public.verified_user_referrals(referral_code_id, owner_user_id, referred_user_id, referred_device_id)
  values(code_id, owner_id, auth.uid(), left(p_device_id, 180))
  on conflict (referred_user_id) do nothing returning id into verified_id;
  if verified_id is null then return jsonb_build_object('success', false, 'reason', 'ALREADY_VERIFIED'); end if;
  insert into public.user_earnings_ledger(owner_user_id, verified_referral_id, amount_cents)
  values(owner_id, verified_id, 20) on conflict (verified_referral_id) do nothing;
  return jsonb_build_object('success', true, 'reward_cents', 20);
end;
$$;

create or replace function public.get_user_earnings_dashboard()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare code_row public.user_referral_codes; referral_total integer; earned_total integer; reserved_total integer; claimable_total integer; target_count integer; history jsonb;
begin
  if auth.uid() is null then raise exception 'IDENTITY_REQUIRED'; end if;
  insert into public.user_referral_codes(owner_user_id) values(auth.uid()) on conflict(owner_user_id) do nothing;
  select * into code_row from public.user_referral_codes where owner_user_id = auth.uid();
  select count(*)::integer into referral_total from public.verified_user_referrals where owner_user_id = auth.uid();
  select coalesce(sum(amount_cents), 0)::integer into earned_total from public.user_earnings_ledger where owner_user_id = auth.uid();
  select coalesce(sum(amount_cents), 0)::integer into reserved_total from public.user_withdrawal_requests where owner_user_id = auth.uid() and status in ('pending','processing','paid');
  claimable_total := greatest(0, floor(referral_total / 50.0)::integer * 1000 - reserved_total);
  target_count := greatest(50, (floor(referral_total / 50.0)::integer + 1) * 50);
  select coalesce(jsonb_agg(row_to_json(h) order by h.created_at desc), '[]'::jsonb) into history from (select id, amount_cents, payment_method, status, rejection_reason, created_at from public.user_withdrawal_requests where owner_user_id = auth.uid() order by created_at desc limit 20) h;
  return jsonb_build_object('referral_code', code_row.referral_code, 'referral_count', referral_total, 'earned_cents', earned_total, 'claimable_cents', claimable_total, 'target_count', target_count, 'target_amount_cents', floor(target_count / 50.0)::integer * 1000, 'history', history);
end;
$$;

create or replace function public.create_user_withdrawal_request(p_payment_method text, p_payment_account text, p_request_key uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare referral_total integer; reserved_total integer; claimable_total integer; existing_request public.user_withdrawal_requests; new_request public.user_withdrawal_requests;
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then raise exception 'AUTHENTICATED_ACCOUNT_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text, 0));
  select * into existing_request from public.user_withdrawal_requests where owner_user_id = auth.uid() and request_key = p_request_key;
  if existing_request.id is not null then return jsonb_build_object('success', true, 'id', existing_request.id, 'status', existing_request.status, 'amount_cents', existing_request.amount_cents); end if;
  select count(*)::integer into referral_total from public.verified_user_referrals where owner_user_id = auth.uid();
  select coalesce(sum(amount_cents), 0)::integer into reserved_total from public.user_withdrawal_requests where owner_user_id = auth.uid() and status in ('pending','processing','paid');
  claimable_total := greatest(0, floor(referral_total / 50.0)::integer * 1000 - reserved_total);
  if claimable_total < 1000 then raise exception 'MINIMUM_WITHDRAWAL_NOT_REACHED'; end if;
  if p_payment_method not in ('bank_transfer','ewallet') then raise exception 'INVALID_PAYMENT_METHOD'; end if;
  if char_length(trim(p_payment_account)) not between 3 and 160 then raise exception 'INVALID_PAYMENT_ACCOUNT'; end if;
  insert into public.user_withdrawal_requests(owner_user_id, amount_cents, referral_count_snapshot, payment_method, payment_account, request_key)
  values(auth.uid(), claimable_total, referral_total, p_payment_method, trim(p_payment_account), p_request_key) returning * into new_request;
  return jsonb_build_object('success', true, 'id', new_request.id, 'status', new_request.status, 'amount_cents', new_request.amount_cents);
end;
$$;

revoke all on function public.claim_user_referral(text, text) from public;
revoke all on function public.get_user_earnings_dashboard() from public;
revoke all on function public.create_user_withdrawal_request(text, text, uuid) from public;
grant execute on function public.claim_user_referral(text, text) to authenticated;
grant execute on function public.get_user_earnings_dashboard() to authenticated;
grant execute on function public.create_user_withdrawal_request(text, text, uuid) to authenticated;

notify pgrst, 'reload schema';
