-- Public user referral links, separate from the KEDAI merchant registry.

create sequence if not exists public.public_user_referral_number_seq start with 1;

create table if not exists public.public_user_referral_links (
  id uuid primary key default gen_random_uuid(),
  referral_number bigint not null unique default nextval('public.public_user_referral_number_seq'),
  referral_code text generated always as (referral_number::text) stored unique,
  owner_device_id text not null unique check (char_length(owner_device_id) between 8 and 180),
  owner_user_id uuid unique references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);

-- Migrate the first numeric implementation to permanent six-character codes.
-- Existing rows receive one new code once; future rows use the same default.
create or replace function public.generate_public_user_referral_code()
returns text language plpgsql volatile security definer set search_path = public
as $$
declare v_code text;
begin
  loop
    v_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from public.public_user_referral_links where referral_code = v_code);
  end loop;
  return v_code;
end;
$$;

do $$
begin
  if exists (
    select 1
    from pg_attribute
    where attrelid = 'public.public_user_referral_links'::regclass
      and attname = 'referral_code'
      and attgenerated = 's'
  ) then
    alter table public.public_user_referral_links
      alter column referral_code drop expression;
  end if;
end
$$;
alter table public.public_user_referral_links
  alter column referral_code set default public.generate_public_user_referral_code();
update public.public_user_referral_links
set referral_code = public.generate_public_user_referral_code()
where referral_code !~ '^[A-Z0-9]{6}$';

revoke all on function public.generate_public_user_referral_code() from public;

create table if not exists public.public_user_referral_conversions (
  id uuid primary key default gen_random_uuid(),
  referral_link_id uuid not null references public.public_user_referral_links(id) on delete restrict,
  owner_user_id uuid references auth.users(id) on delete set null,
  referred_user_id uuid references auth.users(id) on delete cascade,
  referred_device_id text not null unique check (char_length(referred_device_id) between 8 and 180),
  reward_cents integer not null default 20 check (reward_cents = 20),
  verified_at timestamptz not null default now()
);

-- Keep device identity as the required conversion identity. The account ID is
-- optional and only enriches an already verified device when available.
alter table public.public_user_referral_conversions
  alter column referred_user_id drop not null;
alter table public.public_user_referral_conversions
  drop constraint if exists public_user_referral_conversions_referred_user_id_key;
create unique index if not exists public_user_referral_conversions_referred_user_id_uidx
  on public.public_user_referral_conversions(referred_user_id)
  where referred_user_id is not null;

create index if not exists public_user_referral_conversions_owner_idx
  on public.public_user_referral_conversions(owner_user_id, verified_at desc);

create table if not exists public.public_user_referral_withdrawals (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid references auth.users(id) on delete set null,
  owner_device_id text not null check (char_length(owner_device_id) between 8 and 180),
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
  unique (owner_user_id, request_key)
);

alter table public.public_user_referral_withdrawals
  alter column owner_user_id drop not null;
alter table public.public_user_referral_withdrawals
  add column if not exists owner_device_id text;
update public.public_user_referral_withdrawals w
set owner_device_id = l.owner_device_id
from public.public_user_referral_links l
where w.owner_device_id is null and w.owner_user_id = l.owner_user_id;
alter table public.public_user_referral_withdrawals
  alter column owner_device_id set not null;
alter table public.public_user_referral_withdrawals
  drop constraint if exists public_user_referral_withdrawals_owner_user_id_request_key_key;
create unique index if not exists public_user_referral_withdrawals_device_request_key_uidx
  on public.public_user_referral_withdrawals(owner_device_id, request_key);

alter table public.public_user_referral_links enable row level security;
alter table public.public_user_referral_conversions enable row level security;
alter table public.public_user_referral_withdrawals enable row level security;
revoke all on public.public_user_referral_links, public.public_user_referral_conversions, public.public_user_referral_withdrawals from anon, authenticated;
grant select on public.public_user_referral_links, public.public_user_referral_conversions, public.public_user_referral_withdrawals to authenticated;

create or replace function public.public_user_referral_is_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select auth.uid() is not null and exists (select 1 from public.admin_users where user_id = auth.uid()); $$;

revoke all on function public.public_user_referral_is_admin() from public;
grant execute on function public.public_user_referral_is_admin() to authenticated;

drop policy if exists "Public user referral link owner read" on public.public_user_referral_links;
create policy "Public user referral link owner read" on public.public_user_referral_links for select to authenticated using (owner_user_id = auth.uid() or public.public_user_referral_is_admin());
drop policy if exists "Public user referral conversion owner read" on public.public_user_referral_conversions;
create policy "Public user referral conversion owner read" on public.public_user_referral_conversions for select to authenticated using (owner_user_id = auth.uid() or public.public_user_referral_is_admin());
drop policy if exists "Public user referral withdrawal owner read" on public.public_user_referral_withdrawals;
create policy "Public user referral withdrawal owner read" on public.public_user_referral_withdrawals for select to authenticated using (owner_user_id = auth.uid() or public.public_user_referral_is_admin());

create or replace function public.get_or_create_public_user_referral_link(p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_device_id text := left(btrim(p_device_id), 180); v_user_id uuid := auth.uid(); v_row public.public_user_referral_links;
begin
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  insert into public.public_user_referral_links(owner_device_id, owner_user_id, claimed_at)
  values (v_device_id, v_user_id, case when v_user_id is null then null else now() end)
  on conflict (owner_device_id) do update set owner_user_id = coalesce(public.public_user_referral_links.owner_user_id, excluded.owner_user_id), claimed_at = case when public.public_user_referral_links.owner_user_id is null and excluded.owner_user_id is not null then now() else public.public_user_referral_links.claimed_at end;
  select * into v_row from public.public_user_referral_links where owner_device_id = v_device_id;
  if v_user_id is not null then
    update public.public_user_referral_conversions set owner_user_id = v_user_id where referral_link_id = v_row.id and owner_user_id is null;
  end if;
  return jsonb_build_object('referral_code', v_row.referral_code, 'referral_number', v_row.referral_number, 'referral_link', 'https://infinity-global-chat.onrender.com/?ref=' || v_row.referral_code);
end;
$$;

create or replace function public.claim_public_user_referral(p_referral_code text, p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_code text := btrim(p_referral_code); v_device_id text := left(btrim(p_device_id), 180); v_user_id uuid := auth.uid(); v_link public.public_user_referral_links; v_conversion public.public_user_referral_conversions;
begin
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  if v_code !~ '^[A-Z0-9]{6}$' or char_length(v_device_id) < 8 then return jsonb_build_object('success', false, 'reason', 'INVALID_REFERRAL'); end if;
  perform pg_advisory_xact_lock(hashtextextended(v_device_id, 0));
  select * into v_link from public.public_user_referral_links where referral_code = v_code for update;
  if v_link.id is null then return jsonb_build_object('success', false, 'reason', 'INVALID_REFERRAL'); end if;
  if v_link.owner_user_id = v_user_id or v_link.owner_device_id = v_device_id then return jsonb_build_object('success', false, 'reason', 'SELF_REFERRAL'); end if;
  insert into public.public_user_referral_conversions(referral_link_id, owner_user_id, referred_user_id, referred_device_id)
  values (v_link.id, v_link.owner_user_id, v_user_id, v_device_id)
  on conflict (referred_device_id) do nothing returning * into v_conversion;
  if v_conversion.id is null then return jsonb_build_object('success', false, 'reason', 'ALREADY_VERIFIED'); end if;
  return jsonb_build_object('success', true, 'reward_cents', 20);
exception when unique_violation then
  return jsonb_build_object('success', false, 'reason', 'ALREADY_VERIFIED');
end;
$$;

create or replace function public.get_public_user_referral_dashboard(p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_device_id text := left(btrim(p_device_id), 180); v_user_id uuid := auth.uid(); v_link public.public_user_referral_links; v_count integer; v_earned integer; v_reserved integer; v_claimable integer; v_target integer; v_history jsonb;
begin
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  perform public.get_or_create_public_user_referral_link(v_device_id);
  select * into v_link from public.public_user_referral_links where owner_device_id = v_device_id;
  if v_link.id is null or (v_user_id is not null and v_link.owner_user_id is not null and v_link.owner_user_id <> v_user_id) then raise exception 'REFERRAL_LINK_OWNER_MISMATCH'; end if;
  select count(*)::integer, coalesce(sum(reward_cents), 0)::integer into v_count, v_earned from public.public_user_referral_conversions where referral_link_id = v_link.id;
  select coalesce(sum(amount_cents), 0)::integer into v_reserved from public.public_user_referral_withdrawals where owner_device_id = v_device_id and status in ('pending', 'processing', 'paid');
  v_claimable := greatest(0, floor(v_count / 50.0)::integer * 1000 - v_reserved); v_target := greatest(50, (floor(v_count / 50.0)::integer + 1) * 50);
  select coalesce(jsonb_agg(row_to_json(h) order by h.created_at desc), '[]'::jsonb) into v_history from (select id, amount_cents, payment_method, status, rejection_reason, created_at from public.public_user_referral_withdrawals where owner_device_id = v_device_id order by created_at desc limit 20) h;
  return jsonb_build_object('referral_code', v_link.referral_code, 'referral_number', v_link.referral_number, 'referral_link', 'https://infinity-global-chat.onrender.com/?ref=' || v_link.referral_code, 'referral_count', v_count, 'earned_cents', v_earned, 'claimable_cents', v_claimable, 'target_count', v_target, 'target_amount_cents', floor(v_target / 50.0)::integer * 1000, 'history', v_history);
end;
$$;

create or replace function public.get_public_user_referral_dashboard_by_code(p_referral_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_code text := upper(btrim(p_referral_code)); v_link public.public_user_referral_links; v_count integer; v_earned integer; v_reserved integer; v_claimable integer; v_target integer; v_history jsonb;
begin
  if v_code !~ '^[A-Z0-9]{6}$' then raise exception 'INVALID_REFERRAL'; end if;
  select * into v_link from public.public_user_referral_links where referral_code = v_code;
  if v_link.id is null then raise exception 'INVALID_REFERRAL'; end if;
  select count(*)::integer, coalesce(sum(reward_cents), 0)::integer into v_count, v_earned from public.public_user_referral_conversions where referral_link_id = v_link.id;
  select coalesce(sum(amount_cents), 0)::integer into v_reserved from public.public_user_referral_withdrawals where owner_device_id = v_link.owner_device_id and status in ('pending', 'processing', 'paid');
  v_claimable := greatest(0, floor(v_count / 50.0)::integer * 1000 - v_reserved); v_target := greatest(50, (floor(v_count / 50.0)::integer + 1) * 50);
  select coalesce(jsonb_agg(row_to_json(h) order by h.created_at desc), '[]'::jsonb) into v_history from (select id, amount_cents, payment_method, status, rejection_reason, created_at from public.public_user_referral_withdrawals where owner_device_id = v_link.owner_device_id order by created_at desc limit 20) h;
  return jsonb_build_object('referral_code', v_link.referral_code, 'referral_number', v_link.referral_number, 'referral_link', 'https://infinity-global-chat.onrender.com/?ref=' || v_link.referral_code, 'referral_count', v_count, 'earned_cents', v_earned, 'claimable_cents', v_claimable, 'target_count', v_target, 'target_amount_cents', floor(v_target / 50.0)::integer * 1000, 'history', v_history);
end;
$$;

create or replace function public.create_public_user_referral_withdrawal(p_payment_method text, p_payment_account text, p_request_key uuid, p_device_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_user_id uuid := auth.uid(); v_device_id text := left(btrim(p_device_id), 180); v_link public.public_user_referral_links; v_count integer; v_reserved integer; v_claimable integer; v_existing public.public_user_referral_withdrawals; v_new public.public_user_referral_withdrawals;
begin
  if char_length(v_device_id) < 8 then raise exception 'DEVICE_ID_REQUIRED'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
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
  insert into public.public_user_referral_withdrawals(owner_user_id, owner_device_id, amount_cents, referral_count_snapshot, payment_method, payment_account, request_key) values (v_user_id, v_device_id, v_claimable, v_count, p_payment_method, trim(p_payment_account), p_request_key) returning * into v_new;
  return jsonb_build_object('success', true, 'id', v_new.id, 'status', v_new.status, 'amount_cents', v_new.amount_cents);
end;
$$;

create or replace function public.admin_list_public_user_referral_withdrawals()
returns setof public.public_user_referral_withdrawals language sql security definer set search_path = public
as $$ select * from public.public_user_referral_withdrawals where public.public_user_referral_is_admin() order by created_at asc; $$;

create or replace function public.admin_update_public_user_referral_withdrawal(p_withdrawal_id uuid, p_status text, p_rejection_reason text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_row public.public_user_referral_withdrawals;
begin
  if not public.public_user_referral_is_admin() then raise exception 'ADMIN_REQUIRED'; end if;
  if p_status not in ('processing', 'paid', 'rejected') then raise exception 'INVALID_WITHDRAWAL_STATUS'; end if;
  if p_status = 'rejected' and nullif(trim(p_rejection_reason), '') is null then raise exception 'REJECTION_REASON_REQUIRED'; end if;
  update public.public_user_referral_withdrawals set status = p_status, rejection_reason = case when p_status = 'rejected' then trim(p_rejection_reason) else null end, reviewed_at = now(), reviewed_by = auth.uid() where id = p_withdrawal_id and status in ('pending', 'processing') returning * into v_row;
  if v_row.id is null then raise exception 'WITHDRAWAL_NOT_FOUND_OR_CLOSED'; end if;
  return jsonb_build_object('success', true, 'status', v_row.status);
end;
$$;

revoke all on function public.get_or_create_public_user_referral_link(text), public.claim_public_user_referral(text, text), public.get_public_user_referral_dashboard(text), public.get_public_user_referral_dashboard_by_code(text), public.create_public_user_referral_withdrawal(text, text, uuid, text), public.admin_list_public_user_referral_withdrawals(), public.admin_update_public_user_referral_withdrawal(uuid, text, text) from public;
grant execute on function public.get_or_create_public_user_referral_link(text), public.claim_public_user_referral(text, text), public.get_public_user_referral_dashboard(text) to anon, authenticated;
grant execute on function public.get_public_user_referral_dashboard(text), public.create_public_user_referral_withdrawal(text, text, uuid, text), public.admin_list_public_user_referral_withdrawals(), public.admin_update_public_user_referral_withdrawal(uuid, text, text) to anon, authenticated;
revoke execute on function public.get_public_user_referral_dashboard_by_code(text) from anon, authenticated;

notify pgrst, 'reload schema';