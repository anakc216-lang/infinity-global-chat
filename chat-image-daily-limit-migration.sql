-- Replace sticker messages with images and enforce six image sends per UTC day.
-- Run after chat-sticker-message-type-migration.sql.

BEGIN;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS image_url TEXT;

ALTER TABLE public.messages
  DROP CONSTRAINT IF EXISTS messages_sticker_url_valid,
  DROP CONSTRAINT IF EXISTS messages_type_allowed,
  DROP CONSTRAINT IF EXISTS messages_image_url_valid;

UPDATE public.messages
SET type = 'image',
    image_url = COALESCE(
      image_url,
      sticker_url,
      CASE
        WHEN content ~ '^sticker:v1:[0-9]{13}-[a-f0-9-]{36}\.(png|jpg|jpeg|webp|gif)$'
        THEN 'https://rptclztrmprcxjbolkrt.supabase.co/storage/v1/object/public/chat-stickers/' ||
          (regexp_match(content, '^sticker:v1:([0-9]{13}-[a-f0-9-]{36}\.(png|jpg|jpeg|webp|gif))$'))[1]
        ELSE NULL
      END
    ),
    content = 'Image',
    sticker_url = NULL
WHERE type = 'sticker'
   OR image_url IS NOT NULL
   OR content ~ '^sticker:v1:[0-9]{13}-[a-f0-9-]{36}\.(png|jpg|jpeg|webp|gif)$';

UPDATE public.messages
SET type = 'text',
    content = 'Image unavailable',
    image_url = NULL,
    sticker_url = NULL
WHERE type = 'image'
  AND (
    image_url IS NULL
    OR image_url !~ '^https://rptclztrmprcxjbolkrt\.supabase\.co/storage/v1/object/public/chat-stickers/[0-9]{13}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
  );

ALTER TABLE public.messages
  ADD CONSTRAINT messages_type_allowed CHECK (type IN ('text', 'image')),
  ADD CONSTRAINT messages_image_url_valid CHECK (
    (type = 'text' AND image_url IS NULL)
    OR (
      type = 'image'
      AND image_url IS NOT NULL
      AND image_url ~ '^https://rptclztrmprcxjbolkrt\.supabase\.co/storage/v1/object/public/chat-stickers/[0-9]{13}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
    )
  );

CREATE INDEX IF NOT EXISTS messages_daily_images_by_user
  ON public.messages (owner_user_id, created_at)
  WHERE type = 'image' AND owner_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS messages_daily_images_by_device
  ON public.messages (owner_device_id, created_at)
  WHERE type = 'image' AND owner_user_id IS NULL AND owner_device_id IS NOT NULL;

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
  IF NULLIF(BTRIM(p_device_id), '') IS NULL
     OR NULLIF(BTRIM(p_room), '') IS NULL
     OR NULLIF(BTRIM(p_username), '') IS NULL
     OR COALESCE(p_type, '') NOT IN ('text', 'image') THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Message data is incomplete');
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
  WHERE (auth.uid() IS NOT NULL AND user_id = auth.uid())
     OR (auth.uid() IS NULL AND device_id = BTRIM(p_device_id) AND user_id IS NULL)
  ORDER BY created_at ASC
  LIMIT 1;

  IF p_type = 'image' THEN
    v_identity := CASE
      WHEN auth.uid() IS NOT NULL THEN 'user:' || auth.uid()::TEXT
      ELSE 'device:' || BTRIM(p_device_id)
    END;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_identity, 0));

    IF auth.uid() IS NOT NULL THEN
      SELECT COUNT(*)::INTEGER INTO v_images_sent
      FROM public.messages
      WHERE type = 'image'
        AND owner_user_id = auth.uid()
        AND created_at >= v_day_start
        AND created_at < v_day_start + INTERVAL '1 day';
    ELSE
      SELECT COUNT(*)::INTEGER INTO v_images_sent
      FROM public.messages
      WHERE type = 'image'
        AND owner_user_id IS NULL
        AND owner_device_id = BTRIM(p_device_id)
        AND created_at >= v_day_start
        AND created_at < v_day_start + INTERVAL '1 day';
    END IF;

    IF v_images_sent >= 6 THEN
      RETURN JSONB_BUILD_OBJECT(
        'success', FALSE,
        'error', 'IMAGE_DAILY_LIMIT',
        'remaining_images', 0
      );
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

  RETURN JSONB_BUILD_OBJECT(
    'success', TRUE,
    'message_id', v_message_id,
    'remaining_quota', -1,
    'is_lifetime', TRUE
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_daily_image_quota(p_device_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day_start TIMESTAMPTZ := date_trunc('day', CURRENT_TIMESTAMP AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_images_sent INTEGER;
BEGIN
  IF NULLIF(BTRIM(p_device_id), '') IS NULL THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Device data is incomplete');
  END IF;

  IF auth.uid() IS NOT NULL THEN
    SELECT COUNT(*)::INTEGER INTO v_images_sent
    FROM public.messages
    WHERE type = 'image'
      AND owner_user_id = auth.uid()
      AND created_at >= v_day_start
      AND created_at < v_day_start + INTERVAL '1 day';
  ELSE
    SELECT COUNT(*)::INTEGER INTO v_images_sent
    FROM public.messages
    WHERE type = 'image'
      AND owner_user_id IS NULL
      AND owner_device_id = BTRIM(p_device_id)
      AND created_at >= v_day_start
      AND created_at < v_day_start + INTERVAL '1 day';
  END IF;

  RETURN JSONB_BUILD_OBJECT(
    'success', TRUE,
    'limit', 6,
    'remaining_images', GREATEST(0, 6 - v_images_sent)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TEXT) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.get_daily_image_quota(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_daily_image_quota(TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
