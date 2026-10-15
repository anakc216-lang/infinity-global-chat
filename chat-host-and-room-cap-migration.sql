-- Add a transparent, scheduled text host and enforce a 3,500-row cap per room.
-- Run once in the Supabase SQL Editor after the core messages migrations.

CREATE INDEX IF NOT EXISTS idx_messages_room_created_id
  ON public.messages (room, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS public.chat_host_room_activity (
  room text PRIMARY KEY,
  last_activity_at timestamptz NOT NULL
);

ALTER TABLE public.chat_host_room_activity ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chat_host_room_activity FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.chat_host_room_activity TO service_role;

INSERT INTO public.chat_host_room_activity (room, last_activity_at)
SELECT room, max(created_at)
FROM public.messages
WHERE created_at IS NOT NULL
GROUP BY room
ON CONFLICT (room) DO UPDATE
SET last_activity_at = GREATEST(
  public.chat_host_room_activity.last_activity_at,
  EXCLUDED.last_activity_at
);

CREATE OR REPLACE FUNCTION public.track_chat_host_room_activity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  INSERT INTO public.chat_host_room_activity (room, last_activity_at)
  VALUES (NEW.room, COALESCE(NEW.created_at, CURRENT_TIMESTAMP))
  ON CONFLICT (room) DO UPDATE
  SET last_activity_at = GREATEST(
    public.chat_host_room_activity.last_activity_at,
    EXCLUDED.last_activity_at
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.track_chat_host_room_activity() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS track_chat_host_room_activity_after_insert ON public.messages;
CREATE TRIGGER track_chat_host_room_activity_after_insert
AFTER INSERT ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.track_chat_host_room_activity();

CREATE OR REPLACE FUNCTION public.lock_message_room_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('message-room:' || NEW.room, 0));
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.lock_message_room_before_insert() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lock_message_room_before_insert ON public.messages;
CREATE TRIGGER lock_message_room_before_insert
BEFORE INSERT ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.lock_message_room_before_insert();

CREATE OR REPLACE FUNCTION public.keep_message_room_within_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  DELETE FROM public.messages
  WHERE id IN (
    SELECT id
    FROM public.messages
    WHERE room = NEW.room
      AND id <> NEW.id
    ORDER BY created_at DESC NULLS LAST, id DESC
    OFFSET 3499
  );
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.keep_message_room_within_limit() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS keep_message_room_within_limit_after_insert ON public.messages;
CREATE TRIGGER keep_message_room_within_limit_after_insert
AFTER INSERT ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.keep_message_room_within_limit();

-- Disable the older global purge so the room-specific rolling cap controls retention.
DROP TRIGGER IF EXISTS clear_all_messages_at_limit_after_insert ON public.messages;

WITH ranked_messages AS (
  SELECT id, row_number() OVER (
    PARTITION BY room
    ORDER BY created_at DESC NULLS LAST, id DESC
  ) AS room_position
  FROM public.messages
)
DELETE FROM public.messages AS messages
USING ranked_messages
WHERE messages.id = ranked_messages.id
  AND ranked_messages.room_position > 3500;

CREATE OR REPLACE FUNCTION public.get_chat_host_candidates(p_limit integer DEFAULT 20)
RETURNS TABLE (room text, last_activity_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT activity.room, activity.last_activity_at
  FROM public.chat_host_room_activity AS activity
  WHERE activity.last_activity_at <= CURRENT_TIMESTAMP
  ORDER BY activity.last_activity_at ASC, activity.room ASC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
$$;

REVOKE ALL ON FUNCTION public.get_chat_host_candidates(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_chat_host_candidates(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.register_chat_host_rooms(p_rooms text[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  registered_count integer;
BEGIN
  IF p_rooms IS NULL OR cardinality(p_rooms) > 500 THEN
    RAISE EXCEPTION 'Invalid chat host room list';
  END IF;

  INSERT INTO public.chat_host_room_activity (room, last_activity_at)
  SELECT DISTINCT room, CURRENT_TIMESTAMP
  FROM unnest(p_rooms) AS requested(room)
  WHERE room ~ '^[a-z0-9_]{1,100}$'
  ON CONFLICT (room) DO NOTHING;

  GET DIAGNOSTICS registered_count = ROW_COUNT;
  RETURN registered_count;
END;
$$;

REVOKE ALL ON FUNCTION public.register_chat_host_rooms(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.register_chat_host_rooms(text[]) TO service_role;

CREATE OR REPLACE FUNCTION public.post_chat_host_message(
  p_room text,
  p_username text,
  p_avatar text,
  p_content text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  last_activity timestamptz;
BEGIN
  IF NULLIF(BTRIM(p_room), '') IS NULL
     OR NULLIF(BTRIM(p_username), '') IS NULL
     OR NULLIF(BTRIM(p_content), '') IS NULL
     OR LENGTH(p_room) > 100
     OR LENGTH(p_username) > 80
     OR LENGTH(p_avatar) > 20
     OR LENGTH(p_content) > 4000 THEN
    RAISE EXCEPTION 'Invalid chat host message';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('message-room:' || BTRIM(p_room), 0));

  SELECT activity.last_activity_at
  INTO last_activity
  FROM public.chat_host_room_activity AS activity
  WHERE activity.room = BTRIM(p_room)
  FOR UPDATE;

  IF last_activity IS NULL
     OR last_activity > CURRENT_TIMESTAMP THEN
    RETURN FALSE;
  END IF;

  INSERT INTO public.messages (
    room, username, avatar, content, owner_device_id, owner_user_id,
    account_created_at, created_at, updated_at
  )
  VALUES (
    BTRIM(p_room), BTRIM(p_username), COALESCE(p_avatar, '🤖'),
    BTRIM(p_content), 'infinity-chat-host', NULL,
    NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  );

  RETURN TRUE;
END;
$$;

REVOKE ALL ON FUNCTION public.post_chat_host_message(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.post_chat_host_message(text, text, text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
