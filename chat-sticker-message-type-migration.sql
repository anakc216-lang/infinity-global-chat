-- Add a typed sticker model to chat messages.
-- Run after free-chat-access-migration.sql and chat-sticker-storage-migration.sql.

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS type TEXT NOT NULL DEFAULT 'text';

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS sticker_url TEXT;

-- Convert sticker references created by the earlier client implementation.
UPDATE public.messages
SET type = 'sticker',
    sticker_url = 'https://rptclztrmprcxjbolkrt.supabase.co/storage/v1/object/public/chat-stickers/' ||
      (regexp_match(content, '^sticker:v1:([0-9]{13}-[a-f0-9-]{36}\.(png|jpg|jpeg|webp|gif))$'))[1],
    content = 'Sticker'
WHERE content ~ '^sticker:v1:[0-9]{13}-[a-f0-9-]{36}\.(png|jpg|jpeg|webp|gif)$';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'messages_type_allowed'
      AND conrelid = 'public.messages'::regclass
  ) THEN
    ALTER TABLE public.messages
      ADD CONSTRAINT messages_type_allowed CHECK (type IN ('text', 'sticker'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'messages_sticker_url_valid'
      AND conrelid = 'public.messages'::regclass
  ) THEN
    ALTER TABLE public.messages
      ADD CONSTRAINT messages_sticker_url_valid CHECK (
        (type = 'text' AND sticker_url IS NULL)
        OR (
          type = 'sticker'
          AND sticker_url IS NOT NULL
          AND sticker_url ~ '^https://rptclztrmprcxjbolkrt\.supabase\.co/storage/v1/object/public/chat-stickers/[0-9]{13}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
        )
      );
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID);

CREATE OR REPLACE FUNCTION public.check_and_send_message_v2(
  p_device_id TEXT,
  p_room TEXT,
  p_username TEXT,
  p_avatar TEXT,
  p_content TEXT,
  p_reply_to TEXT DEFAULT NULL,
  p_reply_to_id UUID DEFAULT NULL,
  p_type TEXT DEFAULT 'text',
  p_sticker_url TEXT DEFAULT NULL
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
BEGIN
  IF NULLIF(BTRIM(p_device_id), '') IS NULL
     OR NULLIF(BTRIM(p_room), '') IS NULL
     OR NULLIF(BTRIM(p_username), '') IS NULL
     OR COALESCE(p_type, '') NOT IN ('text', 'sticker') THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Message data is incomplete');
  END IF;

  IF p_type = 'text' AND (NULLIF(BTRIM(p_content), '') IS NULL OR p_sticker_url IS NOT NULL) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Invalid text message');
  END IF;

  IF p_type = 'sticker' AND (
    p_sticker_url IS NULL
    OR p_sticker_url !~ '^https://rptclztrmprcxjbolkrt\.supabase\.co/storage/v1/object/public/chat-stickers/[0-9]{13}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(png|jpg|jpeg|webp|gif)$'
  ) THEN
    RETURN JSONB_BUILD_OBJECT('success', FALSE, 'message', 'Invalid sticker URL');
  END IF;

  SELECT created_at INTO v_account_created_at
  FROM public.profiles
  WHERE (auth.uid() IS NOT NULL AND user_id = auth.uid())
    OR (auth.uid() IS NULL AND device_id = BTRIM(p_device_id) AND user_id IS NULL)
  ORDER BY created_at ASC
  LIMIT 1;

  v_content := CASE WHEN p_type = 'sticker' THEN 'Sticker' ELSE LEFT(BTRIM(p_content), 4000) END;

  INSERT INTO public.messages (
    room, username, avatar, content, reply_to, reply_to_id,
    owner_device_id, owner_user_id, account_created_at, created_at, updated_at,
    type, sticker_url
  )
  VALUES (
    BTRIM(p_room), LEFT(BTRIM(p_username), 80), LEFT(COALESCE(p_avatar, ''), 20),
    v_content, p_reply_to, p_reply_to_id, BTRIM(p_device_id), auth.uid(),
    v_account_created_at, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, p_type,
    CASE WHEN p_type = 'sticker' THEN p_sticker_url ELSE NULL END
  )
  RETURNING id INTO v_message_id;

  RETURN JSONB_BUILD_OBJECT(
    'success', TRUE,
    'message_id', v_message_id,
    'remaining_quota', -1,
    'is_lifetime', TRUE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, TEXT, TEXT) TO anon, authenticated;
NOTIFY pgrst, 'reload schema';
