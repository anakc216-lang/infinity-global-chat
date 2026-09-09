-- Repair the existing device-based commission dashboard.
-- Run after public-user-referral-migration.sql and referral-commission-25-migration.sql.
-- This does not create a new referral system or change RLS.

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
  select * into v_link
  from public.public_user_referral_links
  where owner_device_id = v_device_id;

  if v_link.id is null
     or (v_user_id is not null and v_link.owner_user_id is not null and v_link.owner_user_id <> v_user_id) then
    raise exception 'REFERRAL_LINK_OWNER_MISMATCH';
  end if;

  select count(*)::integer
  into v_count
  from public.public_user_referral_conversions
  where referral_link_id = v_link.id;

  v_earned := floor(v_count / 25.0)::integer * 500;

  select coalesce(sum(amount_cents), 0)::integer
  into v_paid
  from public.public_user_referral_payment_ledger
  where owner_device_id = v_device_id;

  select coalesce(sum(amount_cents), 0)::integer
  into v_pending
  from public.public_user_referral_withdrawals
  where owner_device_id = v_device_id
    and status in ('pending', 'processing');

  v_balance := greatest(0, v_earned - v_paid);
  v_claimable := greatest(0, v_balance - v_pending);
  v_target := case
    when v_count = 0 then 25
    when v_count % 25 = 0 then v_count
    else (floor(v_count / 25.0)::integer + 1) * 25
  end;

  select coalesce(jsonb_agg(row_to_json(h) order by h.created_at desc), '[]'::jsonb)
  into v_history
  from (
    select id, amount_cents, payment_method, status, rejection_reason, created_at
    from public.public_user_referral_withdrawals
    where owner_device_id = v_device_id
    order by created_at desc
    limit 20
  ) h;

  return jsonb_build_object(
    'referral_code', v_link.referral_code,
    'referral_number', v_link.referral_number,
    'referral_link', 'https://infinity-global-chat.onrender.com/?ref=' || v_link.referral_code,
    'referral_count', v_count,
    'earned_cents', v_earned,
    'paid_cents', v_paid,
    'balance_cents', v_balance,
    'claimable_cents', v_claimable,
    'target_count', v_target,
    'target_amount_cents', 500,
    'history', v_history
  );
end;
$$;

grant execute on function public.get_public_user_referral_dashboard(text) to anon, authenticated;
notify pgrst, 'reload schema';
