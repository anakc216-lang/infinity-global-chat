-- Global withdrawal milestone lock and verified Razorpay payments.
-- Run after app-install-rating-migration.sql and public-user-referral-migration.sql.

create table if not exists public.global_withdrawal_milestone_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  milestone integer not null check (milestone > 0 and milestone % 1000 = 0),
  razorpay_order_id text not null,
  razorpay_payment_id text not null unique,
  amount_cents integer not null check (amount_cents = 3000),
  currency text not null default 'MYR',
  verification_status text not null default 'verified' check (verification_status = 'verified'),
  verified_at timestamptz not null default now(),
  unique (user_id, milestone),
  unique (razorpay_order_id)
);

create index if not exists global_withdrawal_milestone_payments_user_idx
  on public.global_withdrawal_milestone_payments(user_id, milestone);

alter table public.global_withdrawal_milestone_payments enable row level security;
drop policy if exists "Users read own verified milestone payments" on public.global_withdrawal_milestone_payments;
create policy "Users read own verified milestone payments"
  on public.global_withdrawal_milestone_payments for select to authenticated
  using (user_id = auth.uid());

create or replace function public.get_global_withdrawal_status()
returns jsonb
language sql
security definer
set search_path = public
as $$
  with registered as (
    select count(*)::integer as total_users
    from public.app_installations
    where user_id is not null
  ), current_milestone as (
    select floor(total_users / 1000.0)::integer * 1000 as milestone, total_users
    from registered
  )
  select jsonb_build_object(
    'total_users', current_milestone.total_users,
    'milestone', current_milestone.milestone,
    'locked', current_milestone.milestone > 0 and not exists (
      select 1 from public.global_withdrawal_milestone_payments p
      where p.user_id = auth.uid()
        and p.milestone = current_milestone.milestone
        and p.verification_status = 'verified'
    ),
    'payment_verified', current_milestone.milestone = 0 or exists (
      select 1 from public.global_withdrawal_milestone_payments p
      where p.user_id = auth.uid()
        and p.milestone = current_milestone.milestone
        and p.verification_status = 'verified'
    )
  )
  from current_milestone;
$$;

create or replace function public.record_verified_global_milestone_payment(
  p_user_id uuid,
  p_milestone integer,
  p_razorpay_order_id text,
  p_razorpay_payment_id text,
  p_currency text default 'MYR'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total_users integer;
  v_current_milestone integer;
begin
  if p_user_id is null or p_milestone <= 0 or p_milestone % 1000 <> 0 then
    raise exception 'INVALID_MILESTONE_PAYMENT';
  end if;
  select count(*)::integer into v_total_users from public.app_installations where user_id is not null;
  v_current_milestone := floor(v_total_users / 1000.0)::integer * 1000;
  if p_milestone <> v_current_milestone then
    raise exception 'MILESTONE_IS_NOT_CURRENT';
  end if;
  insert into public.global_withdrawal_milestone_payments (
    user_id, milestone, razorpay_order_id, razorpay_payment_id, amount_cents, currency
  ) values (
    p_user_id, p_milestone, trim(p_razorpay_order_id), trim(p_razorpay_payment_id), 3000, upper(trim(p_currency))
  ) on conflict (user_id, milestone) do nothing;
  return jsonb_build_object('success', true, 'milestone', p_milestone);
end;
$$;

revoke all on function public.record_verified_global_milestone_payment(uuid, integer, text, text, text) from public, anon, authenticated;
grant execute on function public.record_verified_global_milestone_payment(uuid, integer, text, text, text) to service_role;

create or replace function public.create_public_user_referral_withdrawal(
  p_payment_method text, p_payment_account text, p_request_key uuid, p_device_id text
)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_device_id text := left(btrim(p_device_id), 180);
  v_link public.public_user_referral_links;
  v_count integer;
  v_reserved integer;
  v_claimable integer;
  v_existing public.public_user_referral_withdrawals;
  v_new public.public_user_referral_withdrawals;
  v_total_users integer;
  v_milestone integer;
begin
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  select count(*)::integer into v_total_users from public.app_installations where user_id is not null;
  v_milestone := floor(v_total_users / 1000.0)::integer * 1000;
  if v_milestone > 0 and (v_user_id is null or not exists (
    select 1 from public.global_withdrawal_milestone_payments p
    where p.user_id = v_user_id and p.milestone = v_milestone and p.verification_status = 'verified'
  )) then raise exception 'GLOBAL_MILESTONE_PAYMENT_REQUIRED'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_device_id, 0));
  select * into v_link from public.public_user_referral_links where owner_device_id = v_device_id;
  if v_link.id is null or (v_user_id is not null and v_link.owner_user_id is not null and v_link.owner_user_id <> v_user_id) then raise exception 'REFERRAL_LINK_OWNER_MISMATCH'; end if;
  select * into v_existing from public.public_user_referral_withdrawals where owner_device_id = v_device_id and request_key = p_request_key;
  if v_existing.id is not null then return jsonb_build_object('success', true, 'id', v_existing.id, 'status', v_existing.status, 'amount_cents', v_existing.amount_cents); end if;
  select count(*)::integer into v_count from public.public_user_referral_conversions where referral_link_id = v_link.id;
  select coalesce(sum(amount_cents), 0)::integer into v_reserved from public.public_user_referral_withdrawals where owner_device_id = v_device_id and status in ('pending', 'processing', 'paid');
  v_claimable := greatest(0, floor(v_count / 50.0)::integer * 1000 - v_reserved);
  if v_claimable < 1000 then raise exception 'MINIMUM_WITHDRAWAL_NOT_REACHED'; end if;
  if p_payment_method not in ('bank_transfer', 'ewallet') or char_length(trim(p_payment_account)) not between 3 and 160 then raise exception 'INVALID_PAYMENT_DETAILS'; end if;
  insert into public.public_user_referral_withdrawals(owner_user_id, owner_device_id, amount_cents, referral_count_snapshot, payment_method, payment_account, request_key)
  values (v_user_id, v_device_id, v_claimable, v_count, p_payment_method, trim(p_payment_account), p_request_key) returning * into v_new;
  return jsonb_build_object('success', true, 'id', v_new.id, 'status', v_new.status, 'amount_cents', v_new.amount_cents);
end;
$$;

grant execute on function public.get_global_withdrawal_status() to anon, authenticated;
grant execute on function public.record_verified_global_milestone_payment(uuid, integer, text, text, text) to service_role;
grant execute on function public.create_public_user_referral_withdrawal(text, text, uuid, text) to anon, authenticated;

notify pgrst, 'reload schema';
