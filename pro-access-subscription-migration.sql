-- Pro Access subscription entitlement for RM35 every 3 months.
-- Run after multilingual-edit-migration.sql and supabase-moderation-migration.sql.

CREATE TABLE IF NOT EXISTS public.pro_access_entitlements (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  subscription_id TEXT UNIQUE NOT NULL,
  plan_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  starts_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,
  last_payment_id TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS pro_access_entitlements_active_idx
  ON public.pro_access_entitlements(user_id, expires_at)
  WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS pro_access_entitlements_payment_idx
  ON public.pro_access_entitlements(last_payment_id)
  WHERE last_payment_id IS NOT NULL;

ALTER TABLE public.pro_access_entitlements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users read own pro entitlement" ON public.pro_access_entitlements;
CREATE POLICY "Users read own pro entitlement"
  ON public.pro_access_entitlements FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.has_active_pro_access(p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_user_id IS NOT NULL AND (
    public.is_admin(p_user_id)
    OR EXISTS (
      SELECT 1 FROM public.pro_access_entitlements
      WHERE user_id = p_user_id
        AND status IN ('active', 'authenticated', 'charged')
        AND expires_at > NOW()
    )
  );
$$;

REVOKE ALL ON FUNCTION public.has_active_pro_access(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_active_pro_access(UUID) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.record_pro_access_payment(
  p_user_id UUID,
  p_subscription_id TEXT,
  p_plan_id TEXT,
  p_payment_id TEXT,
  p_status TEXT DEFAULT 'charged'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now TIMESTAMPTZ := NOW();
  v_expiry TIMESTAMPTZ;
  v_existing public.pro_access_entitlements;
BEGIN
  IF p_user_id IS NULL OR NULLIF(BTRIM(p_subscription_id), '') IS NULL OR NULLIF(BTRIM(p_plan_id), '') IS NULL THEN
    RAISE EXCEPTION 'INVALID_PRO_ACCESS_PAYMENT';
  END IF;

  SELECT * INTO v_existing
  FROM public.pro_access_entitlements
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_existing.last_payment_id IS NOT NULL AND v_existing.last_payment_id = NULLIF(BTRIM(p_payment_id), '') THEN
    RETURN JSONB_BUILD_OBJECT('success', TRUE, 'duplicate', TRUE, 'user_id', p_user_id, 'expires_at', v_existing.expires_at);
  END IF;

  v_expiry := GREATEST(COALESCE(v_existing.expires_at, v_now), v_now) + INTERVAL '3 months';

  INSERT INTO public.pro_access_entitlements(
    user_id, subscription_id, plan_id, status, starts_at, expires_at, last_payment_id, updated_at
  ) VALUES (
    p_user_id, BTRIM(p_subscription_id), BTRIM(p_plan_id), COALESCE(NULLIF(BTRIM(p_status), ''), 'charged'),
    COALESCE(v_existing.starts_at, v_now), v_expiry, NULLIF(BTRIM(p_payment_id), ''), v_now
  )
  ON CONFLICT (user_id) DO UPDATE SET
    subscription_id = EXCLUDED.subscription_id,
    plan_id = EXCLUDED.plan_id,
    status = EXCLUDED.status,
    expires_at = EXCLUDED.expires_at,
    last_payment_id = EXCLUDED.last_payment_id,
    updated_at = EXCLUDED.updated_at;

  RETURN JSONB_BUILD_OBJECT('success', TRUE, 'user_id', p_user_id, 'expires_at', v_expiry);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_pro_access_status(
  p_subscription_id TEXT,
  p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.pro_access_entitlements
  SET status = BTRIM(p_status), updated_at = NOW()
  WHERE subscription_id = BTRIM(p_subscription_id);
  RETURN JSONB_BUILD_OBJECT('success', TRUE, 'subscription_id', p_subscription_id, 'status', p_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_pro_access_payment(UUID, TEXT, TEXT, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.update_pro_access_status(TEXT, TEXT) TO service_role;

-- Replace the message RPC so free users cannot bypass the frontend lock.
CREATE OR REPLACE FUNCTION public.check_and_send_message_v2(
  p_device_id TEXT,
  p_room TEXT,
  p_username TEXT,
  p_avatar TEXT,
  p_content TEXT,
  p_reply_to TEXT DEFAULT NULL,
  p_reply_to_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id UUID;
  v_account_created_at TIMESTAMPTZ;
BEGIN
  IF NULLIF(BTRIM(p_device_id), '') IS NULL OR NULLIF(BTRIM(p_room), '') IS NULL
     OR NULLIF(BTRIM(p_username), '') IS NULL OR NULLIF(BTRIM(p_content), '') IS NULL THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Message data is incomplete');
  END IF;

  SELECT created_at INTO v_account_created_at FROM public.profiles
  WHERE user_id = auth.uid() OR (auth.uid() IS NULL AND device_id = BTRIM(p_device_id))
  ORDER BY created_at ASC LIMIT 1;

  INSERT INTO public.messages(room, username, avatar, content, reply_to, reply_to_id, owner_device_id, owner_user_id, account_created_at, created_at, updated_at)
  VALUES (BTRIM(p_room), LEFT(BTRIM(p_username), 80), LEFT(COALESCE(p_avatar, ''), 20), LEFT(BTRIM(p_content), 4000), p_reply_to, p_reply_to_id, BTRIM(p_device_id), auth.uid(), v_account_created_at, NOW(), NOW())
  RETURNING id INTO v_message_id;

  RETURN JSONB_BUILD_OBJECT('success', TRUE, 'message_id', v_message_id, 'remaining_quota', -1, 'is_lifetime', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
