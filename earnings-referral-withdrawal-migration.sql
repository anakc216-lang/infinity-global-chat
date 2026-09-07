-- Infinity Chat user Earnings, Referral, and Withdrawal system.
-- Run after supabase-profile-auth-migration.sql and supabase-moderation-migration.sql.

create sequence if not exists public.user_referral_number_seq start with 1;

create table if not exists public.user_referral_codes (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null unique references auth.users(id) on delete cascade,
  referral_number bigint not null unique default nextval('public.user_referral_number_seq'),
  referral_code text generated always as (referral_number::text) stored unique,
  created_at timestamptz not null default now()
);

create table if not exists public.verified_user_referrals (
  id uuid primary key default gen_random_uuid(),
  referral_code_id uuid not null references public.user_referral_codes(id) on delete restrict,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  referred_user_id uuid not null unique references auth.users(id) on delete cascade,
  referred_device_id text,
  verified_at timestamptz not null default now(),
  constraint verified_user_referrals_no_self check (owner_user_id <> referred_user_id),
  constraint verified_user_referrals_code_user_unique unique (referral_code_id, referred_user_id)
);

create index if not exists verified_user_referrals_owner_idx
  on public.verified_user_referrals(owner_user_id, verified_at desc);

create table if not exists public.user_earnings_ledger (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  verified_referral_id uuid not null unique references public.verified_user_referrals(id) on delete restrict,
  amount_cents integer not null check (amount_cents = 20),
  currency text not null default 'MYR' check (currency = 'MYR'),
  entry_type text not null default 'referral_reward' check (entry_type = 'referral_reward'),
  created_at timestamptz not null default now()
);

create index if not exists user_earnings_ledger_owner_idx
  on public.user_earnings_ledger(owner_user_id, created_at desc);

create table if not exists public.user_withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  amount_cents integer not null check (amount_cents > 0),
  referral_count_snapshot integer not null check (referral_count_snapshot >= 50),
  payment_method text not null check (payment_method in ('bank_transfer', 'ewallet')),
  payment_account text not null check (char_length(payment_account) between 3 and 160),
  status text not null default 'pending' check (status in ('pending', 'processing', 'paid', 'rejected')),
  rejection_reason text,
  request_key uuid not null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  constraint user_withdrawals_owner_key_unique unique (owner_user_id, request_key)
);

create index if not exists user_withdrawals_owner_idx
  on public.user_withdrawal_requests(owner_user_id, created_at desc);

alter table public.user_referral_codes enable row level security;
alter table public.verified_user_referrals enable row level security;
alter table public.user_earnings_ledger enable row level security;
alter table public.user_withdrawal_requests enable row level security;

revoke all on public.user_referral_codes, public.verified_user_referrals, public.user_earnings_ledger, public.user_withdrawal_requests from anon, authenticated;
grant select on public.user_referral_codes, public.verified_user_referrals, public.user_earnings_ledger, public.user_withdrawal_requests to authenticated;

create or replace function public.is_user_earnings_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.admin_users where user_id = auth.uid()
  );
$$;

revoke all on function public.is_user_earnings_admin() from public;
grant execute on function public.is_user_earnings_admin() to authenticated;

drop policy if exists "User referral code owner read" on public.user_referral_codes;
create policy "User referral code owner read" on public.user_referral_codes
for select to authenticated using (owner_user_id = auth.uid() or public.is_user_earnings_admin());

drop policy if exists "Verified user referral owner read" on public.verified_user_referrals;
create policy "Verified user referral owner read" on public.verified_user_referrals
for select to authenticated using (owner_user_id = auth.uid() or public.is_user_earnings_admin());

drop policy if exists "User earnings owner read" on public.user_earnings_ledger;
create policy "User earnings owner read" on public.user_earnings_ledger
for select to authenticated using (owner_user_id = auth.uid() or public.is_user_earnings_admin());

drop policy if exists "User withdrawal owner read" on public.user_withdrawal_requests;
create policy "User withdrawal owner read" on public.user_withdrawal_requests
for select to authenticated using (owner_user_id = auth.uid() or public.is_user_earnings_admin());

create or replace function public.get_or_create_user_referral_code()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare code_row public.user_referral_codes;
begin
  if auth.uid() is null then
    raise exception 'IDENTITY_REQUIRED';
  end if;
  insert into public.user_referral_codes(owner_user_id) values (auth.uid())
  on conflict (owner_user_id) do nothing;
  select * into code_row from public.user_referral_codes where owner_user_id = auth.uid();
  return jsonb_build_object('referral_code', code_row.referral_code, 'referral_number', code_row.referral_number);
end;
$$;

create or replace function public.claim_user_referral(p_referral_code text, p_device_id text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare owner_id uuid; code_id uuid; verified_id uuid;
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    return jsonb_build_object('success', false, 'reason', 'AUTHENTICATED_ACCOUNT_REQUIRED');
  end if;
  select id, owner_user_id into code_id, owner_id
  from public.user_referral_codes where referral_code = trim(p_referral_code);
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

create or replace function public.admin_list_user_withdrawals()
returns setof public.user_withdrawal_requests language sql security definer set search_path = public
as $$ select * from public.user_withdrawal_requests where public.is_user_earnings_admin() order by created_at asc; $$;

create or replace function public.admin_update_user_withdrawal(p_withdrawal_id uuid, p_status text, p_rejection_reason text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare row_data public.user_withdrawal_requests;
begin
  if not public.is_user_earnings_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if p_status not in ('processing','paid','rejected') then raise exception 'INVALID_WITHDRAWAL_STATUS'; end if;
  if p_status = 'rejected' and nullif(trim(p_rejection_reason), '') is null then raise exception 'REJECTION_REASON_REQUIRED'; end if;
  update public.user_withdrawal_requests set status=p_status, rejection_reason=case when p_status='rejected' then trim(p_rejection_reason) else null end, reviewed_at=now(), reviewed_by=auth.uid() where id=p_withdrawal_id and status in ('pending','processing') returning * into row_data;
  if row_data.id is null then raise exception 'WITHDRAWAL_NOT_FOUND_OR_CLOSED'; end if;
  return jsonb_build_object('success', true, 'status', row_data.status);
end;
$$;

revoke all on function public.get_or_create_user_referral_code() from public;
revoke all on function public.claim_user_referral(text, text) from public;
revoke all on function public.get_user_earnings_dashboard() from public;
revoke all on function public.create_user_withdrawal_request(text, text, uuid) from public;
revoke all on function public.admin_list_user_withdrawals() from public;
revoke all on function public.admin_update_user_withdrawal(uuid, text, text) from public;
grant execute on function public.get_or_create_user_referral_code() to authenticated;
grant execute on function public.claim_user_referral(text, text) to authenticated;
grant execute on function public.get_user_earnings_dashboard() to authenticated;
grant execute on function public.create_user_withdrawal_request(text, text, uuid) to authenticated;
grant execute on function public.admin_list_user_withdrawals() to authenticated;
grant execute on function public.admin_update_user_withdrawal(uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
