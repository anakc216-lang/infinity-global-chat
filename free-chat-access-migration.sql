-- Allow anonymous and authenticated users to send unlimited chat messages.
-- Run after pro-access-subscription-migration.sql on existing deployments.

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