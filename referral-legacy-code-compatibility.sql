-- Compatibility repair for previously shared numeric referral links.
-- Run after public-user-referral-migration.sql and referral-commission-25-migration.sql.
-- Existing tables and referral ownership rules remain unchanged.

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
begin
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then v_user_id := null; end if;
  if v_code !~ '^(?:[A-Z0-9]{6}|[0-9]{1,20})$' or char_length(v_device_id) < 8 then
    return jsonb_build_object('success', false, 'reason', 'INVALID_REFERRAL');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_device_id, 0));
  select * into v_link
  from public.public_user_referral_links
  where referral_code = v_code
     or (v_code ~ '^[0-9]+$' and referral_number::text = v_code)
  limit 1
  for update;

  if v_link.id is null then return jsonb_build_object('success', false, 'reason', 'INVALID_REFERRAL'); end if;
  if v_link.owner_user_id = v_user_id or v_link.owner_device_id = v_device_id then
    return jsonb_build_object('success', false, 'reason', 'SELF_REFERRAL');
  end if;

  insert into public.public_user_referral_conversions(referral_link_id, owner_user_id, referred_user_id, referred_device_id)
  values (v_link.id, v_link.owner_user_id, v_user_id, v_device_id)
  on conflict (referred_device_id) do nothing returning * into v_conversion;
  if v_conversion.id is null then return jsonb_build_object('success', false, 'reason', 'ALREADY_VERIFIED'); end if;

  select count(*)::integer into v_count
  from public.public_user_referral_conversions
  where referral_link_id = v_link.id;
  return jsonb_build_object('success', true, 'reward_cents', (floor(v_count / 25.0)::integer - floor((v_count - 1) / 25.0)::integer) * 500);
exception when unique_violation then
  return jsonb_build_object('success', false, 'reason', 'ALREADY_VERIFIED');
end;
$$;

grant execute on function public.claim_public_user_referral(text, text) to anon, authenticated;
notify pgrst, 'reload schema';
