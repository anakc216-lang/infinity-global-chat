-- Multilingual message support and owner-safe editing.
-- Run after supabase-migrations-FIXED.sql. Existing rows remain readable;
-- only messages sent through v2 can be edited by their originating device.

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS owner_device_id TEXT;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS owner_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS reply_to_id UUID REFERENCES public.messages(id) ON DELETE SET NULL;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS account_created_at TIMESTAMPTZ;

UPDATE public.messages
SET updated_at = COALESCE(updated_at, created_at, CURRENT_TIMESTAMP)
WHERE updated_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_messages_owner_device_id
  ON public.messages(owner_device_id);

CREATE INDEX IF NOT EXISTS idx_messages_owner_user_id
  ON public.messages(owner_user_id);

CREATE INDEX IF NOT EXISTS idx_messages_reply_to_id
  ON public.messages(reply_to_id);

DROP FUNCTION IF EXISTS public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID);

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.check_and_send_message_v2(
  p_device_id TEXT,
  p_room TEXT,
  p_username TEXT,
  p_avatar TEXT,
  p_content TEXT,
  p_reply_to TEXT DEFAULT NULL,
  p_reply_to_id UUID DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message_id UUID;
  v_account_created_at TIMESTAMPTZ;
BEGIN
  IF NULLIF(btrim(p_device_id), '') IS NULL
     OR NULLIF(btrim(p_room), '') IS NULL
     OR NULLIF(btrim(p_username), '') IS NULL
     OR NULLIF(btrim(p_content), '') IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'message', 'Message data is incomplete');
  END IF;

    SELECT created_at INTO v_account_created_at
    FROM public.profiles
    WHERE (auth.uid() IS NOT NULL AND user_id = auth.uid())
      OR (auth.uid() IS NULL AND device_id = btrim(p_device_id) AND user_id IS NULL)
    ORDER BY created_at ASC
    LIMIT 1;

    INSERT INTO public.messages (room, username, avatar, content, reply_to, reply_to_id, owner_device_id, owner_user_id, account_created_at, created_at, updated_at)
    VALUES (btrim(p_room), left(btrim(p_username), 80), left(COALESCE(p_avatar, ''), 20), left(btrim(p_content), 4000), p_reply_to, p_reply_to_id, btrim(p_device_id), auth.uid(), v_account_created_at, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
  RETURNING id INTO v_message_id;

  RETURN jsonb_build_object('success', TRUE, 'message_id', v_message_id, 'remaining_quota', -1, 'is_lifetime', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_message(
  p_message_id UUID,
  p_device_id TEXT,
  p_content TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_message public.messages;
BEGIN
  IF NULLIF(btrim(p_device_id), '') IS NULL OR NULLIF(btrim(p_content), '') IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'message', 'Message data is incomplete');
  END IF;

  UPDATE public.messages
  SET content = left(btrim(p_content), 4000), updated_at = CURRENT_TIMESTAMP
  WHERE id = p_message_id
    AND ((auth.uid() IS NOT NULL AND owner_user_id = auth.uid())
      OR (auth.uid() IS NULL AND owner_device_id = btrim(p_device_id)))
  RETURNING * INTO v_message;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'message', 'Message cannot be edited by this device');
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'message', to_jsonb(v_message));
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edit_message(UUID, TEXT, TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
