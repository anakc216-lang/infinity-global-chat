-- Enforce Malaysia-only read access and paid global chat access.
-- Run after pro-access-subscription-migration.sql, chat-image-daily-limit-migration.sql,
-- my-videos-migration.sql, speed-job-public-jobs.sql,
-- speed-job-optional-fields-migration.sql, and supabase-moderation-migration.sql.

BEGIN;

ALTER TABLE public.pro_access_entitlements
  ADD COLUMN IF NOT EXISTS last_payment_amount INTEGER,
  ADD COLUMN IF NOT EXISTS last_payment_currency TEXT,
  ADD COLUMN IF NOT EXISTS is_lifetime BOOLEAN NOT NULL DEFAULT FALSE;

CREATE OR REPLACE FUNCTION public.has_active_pro_access(p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_user_id IS NOT NULL
    AND (auth.role() = 'service_role' OR p_user_id = auth.uid())
    AND (
      public.is_admin(p_user_id)
      OR EXISTS (
        SELECT 1
        FROM public.pro_access_entitlements
        WHERE user_id = p_user_id
          AND status IN ('active', 'authenticated', 'charged', 'cancelled', 'paused', 'halted', 'completed')
          AND (is_lifetime OR expires_at > NOW())
      )
    );
$$;

REVOKE ALL ON FUNCTION public.has_active_pro_access(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_active_pro_access(UUID) TO anon, authenticated, service_role;
GRANT SELECT ON TABLE public.pro_access_entitlements TO authenticated;

DROP FUNCTION IF EXISTS public.record_pro_access_payment(UUID, TEXT, TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.record_pro_access_payment(
  p_user_id UUID,
  p_subscription_id TEXT,
  p_plan_id TEXT,
  p_payment_id TEXT,
  p_amount INTEGER,
  p_currency TEXT,
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
  IF p_user_id IS NULL
     OR NULLIF(BTRIM(p_subscription_id), '') IS NULL
     OR NULLIF(BTRIM(p_plan_id), '') IS NULL
     OR NULLIF(BTRIM(p_payment_id), '') IS NULL
     OR p_amount IS DISTINCT FROM 3000
     OR UPPER(BTRIM(COALESCE(p_currency, ''))) <> 'MYR'
     OR COALESCE(NULLIF(BTRIM(p_status), ''), 'charged') <> 'charged' THEN
    RAISE EXCEPTION 'INVALID_PRO_ACCESS_PAYMENT';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::TEXT, 0));

  SELECT * INTO v_existing
  FROM public.pro_access_entitlements
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_existing.last_payment_id = BTRIM(p_payment_id) THEN
    RETURN JSONB_BUILD_OBJECT('success', TRUE, 'duplicate', TRUE, 'user_id', p_user_id, 'expires_at', v_existing.expires_at);
  END IF;

  v_expiry := GREATEST(COALESCE(v_existing.expires_at, v_now), v_now) + INTERVAL '6 months';

  INSERT INTO public.pro_access_entitlements(
    user_id, subscription_id, plan_id, status, starts_at, expires_at, last_payment_id,
    last_payment_amount, last_payment_currency, updated_at
  ) VALUES (
    p_user_id, BTRIM(p_subscription_id), BTRIM(p_plan_id), 'charged',
    COALESCE(v_existing.starts_at, v_now), v_expiry, BTRIM(p_payment_id),
    p_amount, UPPER(BTRIM(p_currency)), v_now
  )
  ON CONFLICT (user_id) DO UPDATE SET
    subscription_id = EXCLUDED.subscription_id,
    plan_id = EXCLUDED.plan_id,
    status = EXCLUDED.status,
    expires_at = EXCLUDED.expires_at,
    last_payment_id = EXCLUDED.last_payment_id,
    last_payment_amount = EXCLUDED.last_payment_amount,
    last_payment_currency = EXCLUDED.last_payment_currency,
    updated_at = EXCLUDED.updated_at;

  RETURN JSONB_BUILD_OBJECT('success', TRUE, 'user_id', p_user_id, 'expires_at', v_expiry);
END;
$$;

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
     OR p_amount IS DISTINCT FROM 4000
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
    p_user_id, 'lifetime_' || BTRIM(p_payment_id), 'pro_lifetime_rm40', 'charged',
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

CREATE OR REPLACE FUNCTION public.update_pro_access_payment_status(
  p_payment_id TEXT,
  p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role'
     OR NULLIF(BTRIM(p_payment_id), '') IS NULL
     OR BTRIM(p_status) NOT IN ('refunded', 'disputed') THEN
    RAISE EXCEPTION 'INVALID_PRO_ACCESS_PAYMENT_STATUS';
  END IF;

  UPDATE public.pro_access_entitlements
  SET status = BTRIM(p_status), updated_at = NOW()
  WHERE last_payment_id = BTRIM(p_payment_id)
    AND is_lifetime = TRUE;

  RETURN JSONB_BUILD_OBJECT('success', TRUE, 'payment_id', p_payment_id, 'status', p_status);
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

REVOKE ALL ON FUNCTION public.record_pro_access_payment(UUID, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_pro_access_status(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_pro_access_lifetime_payment(UUID, TEXT, INTEGER, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_pro_access_payment_status(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_pro_access_payment(UUID, TEXT, TEXT, TEXT, INTEGER, TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.update_pro_access_status(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_pro_access_lifetime_payment(UUID, TEXT, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.update_pro_access_payment_status(TEXT, TEXT) TO service_role;

-- Restrictive policies apply in addition to any existing permissive message policy.
DROP POLICY IF EXISTS "Paid users can read global chat rooms" ON public.messages;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'messages' AND column_name = 'is_hidden'
  ) THEN
    EXECUTE 'CREATE POLICY "Paid users can read global chat rooms"
      ON public.messages AS RESTRICTIVE FOR SELECT TO anon, authenticated
      USING (is_hidden = FALSE AND (room = ''malaysia'' OR public.has_active_pro_access(auth.uid())))';
  ELSE
    EXECUTE 'CREATE POLICY "Paid users can read global chat rooms"
      ON public.messages AS RESTRICTIVE FOR SELECT TO anon, authenticated
      USING (room = ''malaysia'' OR public.has_active_pro_access(auth.uid()))';
  END IF;
END;
$$;

-- MyVideos stays inaccessible to free users even when someone calls its RPCs directly.
DROP POLICY IF EXISTS "MyVideos requires Pro Access" ON public.my_videos;
CREATE POLICY "MyVideos requires Pro Access"
  ON public.my_videos AS RESTRICTIVE FOR SELECT TO anon, authenticated
  USING (public.has_active_pro_access(auth.uid()));

DO $$
BEGIN
  IF to_regprocedure('public.create_my_video(text,text,text,text,text)') IS NOT NULL
     AND to_regprocedure('public.create_my_video_unlocked(text,text,text,text,text)') IS NULL THEN
    ALTER FUNCTION public.create_my_video(TEXT, TEXT, TEXT, TEXT, TEXT) RENAME TO create_my_video_unlocked;
  END IF;
  IF to_regprocedure('public.get_my_video_owned_ids(uuid[],text)') IS NOT NULL
     AND to_regprocedure('public.get_my_video_owned_ids_unlocked(uuid[],text)') IS NULL THEN
    ALTER FUNCTION public.get_my_video_owned_ids(UUID[], TEXT) RENAME TO get_my_video_owned_ids_unlocked;
  END IF;
  IF to_regprocedure('public.delete_my_video(uuid,text)') IS NOT NULL
     AND to_regprocedure('public.delete_my_video_unlocked(uuid,text)') IS NULL THEN
    ALTER FUNCTION public.delete_my_video(UUID, TEXT) RENAME TO delete_my_video_unlocked;
  END IF;
  IF to_regprocedure('public.toggle_my_video_like(uuid,text)') IS NOT NULL
     AND to_regprocedure('public.toggle_my_video_like_unlocked(uuid,text)') IS NULL THEN
    ALTER FUNCTION public.toggle_my_video_like(UUID, TEXT) RENAME TO toggle_my_video_like_unlocked;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.create_my_video_unlocked(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_my_video_owned_ids_unlocked(UUID[], TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.delete_my_video_unlocked(UUID, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.toggle_my_video_like_unlocked(UUID, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_my_video(
  p_device_id TEXT, p_username TEXT, p_title TEXT, p_video_url TEXT, p_video_format TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'PRO_ACCESS_REQUIRED');
  END IF;
  RETURN public.create_my_video_unlocked(p_device_id, p_username, p_title, p_video_url, p_video_format);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_video_owned_ids(p_video_ids UUID[], p_device_id TEXT)
RETURNS UUID[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN ARRAY[]::UUID[];
  END IF;
  RETURN public.get_my_video_owned_ids_unlocked(p_video_ids, p_device_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_my_video(p_video_id UUID, p_device_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'PRO_ACCESS_REQUIRED');
  END IF;
  RETURN public.delete_my_video_unlocked(p_video_id, p_device_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.toggle_my_video_like(p_video_id UUID, p_device_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'PRO_ACCESS_REQUIRED');
  END IF;
  RETURN public.toggle_my_video_like_unlocked(p_video_id, p_device_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_my_video(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_video_owned_ids(UUID[], TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_my_video(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.toggle_my_video_like(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_my_video(TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_video_owned_ids(UUID[], TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_video(UUID, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.toggle_my_video_like(UUID, TEXT) TO anon, authenticated;

-- Speed Job uses the same Pro entitlement for browsing and every mutation.
DROP POLICY IF EXISTS "Speed Job requires Pro Access" ON public.speed_job_posts;
CREATE POLICY "Speed Job requires Pro Access"
  ON public.speed_job_posts AS RESTRICTIVE FOR SELECT TO anon, authenticated
  USING (public.has_active_pro_access(auth.uid()));

DROP POLICY IF EXISTS "Speed Job insert requires Pro Access" ON public.speed_job_posts;
CREATE POLICY "Speed Job insert requires Pro Access"
  ON public.speed_job_posts AS RESTRICTIVE FOR INSERT TO anon, authenticated
  WITH CHECK (public.has_active_pro_access(auth.uid()));

DROP POLICY IF EXISTS "Speed Job update requires Pro Access" ON public.speed_job_posts;
CREATE POLICY "Speed Job update requires Pro Access"
  ON public.speed_job_posts AS RESTRICTIVE FOR UPDATE TO anon, authenticated
  USING (public.has_active_pro_access(auth.uid()))
  WITH CHECK (public.has_active_pro_access(auth.uid()));

DROP POLICY IF EXISTS "Speed Job delete requires Pro Access" ON public.speed_job_posts;
CREATE POLICY "Speed Job delete requires Pro Access"
  ON public.speed_job_posts AS RESTRICTIVE FOR DELETE TO anon, authenticated
  USING (public.has_active_pro_access(auth.uid()));

DO $$
BEGIN
  IF to_regprocedure('public.get_speed_job_posts(text)') IS NOT NULL
     AND to_regprocedure('public.get_speed_job_posts_unlocked(text)') IS NULL THEN
    ALTER FUNCTION public.get_speed_job_posts(TEXT) RENAME TO get_speed_job_posts_unlocked;
  END IF;
  IF to_regprocedure('public.create_speed_job_post(text,text,text,text,text,text[],text,text,integer,text,text,text,text,text)') IS NOT NULL
     AND to_regprocedure('public.create_speed_job_post_unlocked(text,text,text,text,text,text[],text,text,integer,text,text,text,text,text)') IS NULL THEN
    ALTER FUNCTION public.create_speed_job_post(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) RENAME TO create_speed_job_post_unlocked;
  END IF;
  IF to_regprocedure('public.update_speed_job_post(uuid,text,text,text,text,text,text[],text,text,integer,text,text,text,text,text)') IS NOT NULL
     AND to_regprocedure('public.update_speed_job_post_unlocked(uuid,text,text,text,text,text,text[],text,text,integer,text,text,text,text,text)') IS NULL THEN
    ALTER FUNCTION public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) RENAME TO update_speed_job_post_unlocked;
  END IF;
  IF to_regprocedure('public.update_speed_job_post(uuid,text,text,text,text,text[],text,text,integer,text,text,text,text)') IS NOT NULL
     AND to_regprocedure('public.update_speed_job_post_unlocked_legacy(uuid,text,text,text,text,text[],text,text,integer,text,text,text,text)') IS NULL THEN
    ALTER FUNCTION public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT) RENAME TO update_speed_job_post_unlocked_legacy;
  END IF;
  IF to_regprocedure('public.delete_speed_job_post(uuid,text)') IS NOT NULL
     AND to_regprocedure('public.delete_speed_job_post_unlocked(uuid,text)') IS NULL THEN
    ALTER FUNCTION public.delete_speed_job_post(UUID, TEXT) RENAME TO delete_speed_job_post_unlocked;
  END IF;
  IF to_regprocedure('public.update_speed_job_post_unlocked_legacy(uuid,text,text,text,text,text[],text,text,integer,text,text,text,text)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.update_speed_job_post_unlocked_legacy(UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.get_speed_job_posts_unlocked(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_speed_job_post_unlocked(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_speed_job_post_unlocked(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.delete_speed_job_post_unlocked(UUID, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_speed_job_posts(p_post_type TEXT DEFAULT NULL)
RETURNS TABLE (
  id UUID, room TEXT, owner_device_id TEXT, owner_username TEXT, owner_avatar TEXT,
  post_type TEXT, job_type TEXT, location TEXT, contact_info TEXT, social_links TEXT[],
  pay TEXT, schedule_text TEXT, pack_need INTEGER, gender TEXT, description TEXT,
  status TEXT, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RAISE EXCEPTION 'PRO_ACCESS_REQUIRED';
  END IF;
  RETURN QUERY SELECT * FROM public.get_speed_job_posts_unlocked(p_post_type);
END;
$$;

CREATE OR REPLACE FUNCTION public.create_speed_job_post(
  p_room TEXT, p_post_type TEXT, p_job_type TEXT, p_location TEXT,
  p_contact_info TEXT, p_social_links TEXT[], p_pay TEXT, p_schedule_text TEXT,
  p_pack_need INTEGER, p_gender TEXT, p_description TEXT, p_owner_device_id TEXT,
  p_owner_username TEXT, p_owner_avatar TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'PRO_ACCESS_REQUIRED');
  END IF;
  RETURN public.create_speed_job_post_unlocked(
    p_room, p_post_type, p_job_type, p_location, p_contact_info, p_social_links,
    p_pay, p_schedule_text, p_pack_need, p_gender, p_description, p_owner_device_id,
    p_owner_username, p_owner_avatar
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_speed_job_post(
  p_id UUID, p_room TEXT, p_post_type TEXT, p_job_type TEXT, p_location TEXT,
  p_contact_info TEXT, p_social_links TEXT[], p_pay TEXT, p_schedule_text TEXT,
  p_pack_need INTEGER, p_gender TEXT, p_description TEXT, p_owner_device_id TEXT,
  p_owner_username TEXT, p_owner_avatar TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'PRO_ACCESS_REQUIRED');
  END IF;
  RETURN public.update_speed_job_post_unlocked(
    p_id, p_room, p_post_type, p_job_type, p_location, p_contact_info, p_social_links,
    p_pay, p_schedule_text, p_pack_need, p_gender, p_description, p_owner_device_id,
    p_owner_username, p_owner_avatar
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_speed_job_post(p_id UUID, p_owner_device_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'PRO_ACCESS_REQUIRED');
  END IF;
  RETURN public.delete_speed_job_post_unlocked(p_id, p_owner_device_id);
END;
$$;

REVOKE ALL ON FUNCTION public.get_speed_job_posts(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_speed_job_post(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_speed_job_post(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_speed_job_posts(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_speed_job_post(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_speed_job_post(UUID, TEXT) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID);

CREATE FUNCTION public.check_and_send_message_v2(
  p_device_id TEXT,
  p_room TEXT,
  p_username TEXT,
  p_avatar TEXT,
  p_content TEXT,
  p_reply_to TEXT DEFAULT NULL,
  p_reply_to_id UUID DEFAULT NULL,
  p_type TEXT DEFAULT 'text',
  p_image_url TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id UUID;
  v_account_created_at TIMESTAMPTZ;
  v_content TEXT;
  v_identity TEXT;
  v_day_start TIMESTAMPTZ := date_trunc('day', CURRENT_TIMESTAMP AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_images_sent INTEGER;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_active_pro_access(auth.uid()) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'PRO_ACCESS_REQUIRED', 'message', 'Pro Access is required to send messages');
  END IF;

  IF NULLIF(BTRIM(p_device_id), '') IS NULL
     OR NULLIF(BTRIM(p_room), '') IS NULL
     OR NULLIF(BTRIM(p_username), '') IS NULL
     OR COALESCE(p_type, '') NOT IN ('text', 'image') THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Message data is incomplete');
  END IF;

  IF p_room !~ '^[a-z][a-z0-9_]{1,63}$' THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Unknown chat room');
  END IF;

  IF p_type = 'text' AND (NULLIF(BTRIM(p_content), '') IS NULL OR p_image_url IS NOT NULL) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Invalid text message');
  END IF;

  IF p_type = 'image' AND (
    p_image_url IS NULL
    OR p_image_url !~ '^https://rptclztrmprcxjbolkrt\.supabase\.co/storage/v1/object/public/chat-stickers/[0-9]{13}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
  ) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Invalid image URL');
  END IF;

  SELECT created_at INTO v_account_created_at
  FROM public.profiles
  WHERE user_id = auth.uid()
  ORDER BY created_at ASC
  LIMIT 1;

  IF p_type = 'image' THEN
    v_identity := 'user:' || auth.uid()::TEXT;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_identity, 0));

    SELECT COUNT(*)::INTEGER INTO v_images_sent
    FROM public.messages
    WHERE type = 'image'
      AND owner_user_id = auth.uid()
      AND created_at >= v_day_start
      AND created_at < v_day_start + INTERVAL '1 day';

    IF v_images_sent >= 6 THEN
      RETURN JSONB_BUILD_OBJECT('success', FALSE, 'error', 'IMAGE_DAILY_LIMIT', 'remaining_images', 0);
    END IF;
  END IF;

  v_content := CASE WHEN p_type = 'image' THEN 'Image' ELSE LEFT(BTRIM(p_content), 4000) END;

  INSERT INTO public.messages (
    room, username, avatar, content, reply_to, reply_to_id,
    owner_device_id, owner_user_id, account_created_at, created_at, updated_at,
    type, image_url
  )
  VALUES (
    BTRIM(p_room), LEFT(BTRIM(p_username), 80), LEFT(COALESCE(p_avatar, ''), 20),
    v_content, p_reply_to, p_reply_to_id, BTRIM(p_device_id), auth.uid(),
    v_account_created_at, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, p_type,
    CASE WHEN p_type = 'image' THEN p_image_url ELSE NULL END
  )
  RETURNING id INTO v_message_id;

  IF p_type = 'image' THEN
    RETURN JSONB_BUILD_OBJECT(
      'success', TRUE,
      'message_id', v_message_id,
      'remaining_quota', -1,
      'is_lifetime', TRUE,
      'remaining_images', GREATEST(0, 5 - v_images_sent)
    );
  END IF;

  RETURN JSONB_BUILD_OBJECT('success', TRUE, 'message_id', v_message_id, 'remaining_quota', -1, 'is_lifetime', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
