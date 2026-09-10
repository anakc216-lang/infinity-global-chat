-- Keep referral activity and historical records, but disable new automatic cash requests.
-- Run after all referral withdrawal migrations.
-- Existing rows are not updated, deleted, or reset. Admins may still review existing requests.

create or replace function public.create_public_user_referral_withdrawal(
  p_payment_method text,
  p_payment_account text,
  p_request_key uuid,
  p_device_id text
)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  raise exception 'REFERRAL_CASH_CAMPAIGN_NOT_ACTIVE';
end;
$$;

revoke all on function public.create_public_user_referral_withdrawal(text, text, uuid, text) from public;
grant execute on function public.create_public_user_referral_withdrawal(text, text, uuid, text) to anon, authenticated;
notify pgrst, 'reload schema';
