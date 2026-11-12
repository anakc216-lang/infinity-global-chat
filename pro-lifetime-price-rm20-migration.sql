CREATE OR REPLACE FUNCTION public.record_pro_access_lifetime_payment(
  p_user_id UUID,
  p_payment_id TEXT,
  p_amount INTEGER,
  p_currency TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_existing public.pro_access_entitlements;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role'
     OR p_user_id IS NULL
     OR NULLIF(BTRIM(p_payment_id), '') IS NULL
     OR p_amount IS DISTINCT FROM 2000
     OR UPPER(BTRIM(COALESCE(p_currency, ''))) <> 'MYR' THEN
    RAISE EXCEPTION 'INVALID_PRO_ACCESS_LIFETIME_PAYMENT';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 0));

  SELECT * INTO v_existing
  FROM public.pro_access_entitlements
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_existing.last_payment_id = BTRIM(p_payment_id) THEN
    RETURN JSONB_BUILD_OBJECT('success', TRUE, 'duplicate', TRUE, 'user_id', p_user_id, 'is_lifetime', TRUE);
  END IF;

  INSERT INTO public.pro_access_entitlements(
    user_id, subscription_id, plan_id, status, starts_at, expires_at, last_payment_id,
    last_payment_amount, last_payment_currency, is_lifetime, updated_at
  ) VALUES (
    p_user_id, 'lifetime_' || BTRIM(p_payment_id), 'pro_lifetime_rm20', 'charged',
    v_now, 'infinity'::TIMESTAMPTZ, BTRIM(p_payment_id),
    p_amount, UPPER(BTRIM(p_currency)), TRUE, v_now
  )
  ON CONFLICT (user_id) DO UPDATE SET
    subscription_id = EXCLUDED.subscription_id,
    plan_id = EXCLUDED.plan_id,
    status = EXCLUDED.status,
    starts_at = EXCLUDED.starts_at,
    expires_at = EXCLUDED.expires_at,
    last_payment_id = EXCLUDED.last_payment_id,
    last_payment_amount = EXCLUDED.last_payment_amount,
    last_payment_currency = EXCLUDED.last_payment_currency,
    is_lifetime = TRUE,
    updated_at = EXCLUDED.updated_at;

  RETURN JSONB_BUILD_OBJECT('success', TRUE, 'user_id', p_user_id, 'is_lifetime', TRUE);
END;
$$;
