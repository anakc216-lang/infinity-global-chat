-- Require the posting browser's private device ID to manage a MyVideo.
-- Run after my-videos-migration.sql and paid-global-chat-access-migration.sql, if installed.
-- Run this entire file in the SQL Editor; do not run a selected section by itself.
-- Then run my-video-playlists-migration.sql to enable account playlists and editing.

ALTER TABLE public.my_videos
  ALTER COLUMN owner_device_id DROP NOT NULL;

DROP INDEX IF EXISTS public.idx_my_videos_device_created;

CREATE TABLE IF NOT EXISTS public.my_video_ownership (
  video_id UUID PRIMARY KEY REFERENCES public.my_videos(id) ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED,
  owner_device_id TEXT NOT NULL CHECK (char_length(btrim(owner_device_id)) BETWEEN 1 AND 128),
  owner_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

ALTER TABLE public.my_video_ownership ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.my_video_ownership FROM PUBLIC, anon, authenticated;

INSERT INTO public.my_video_ownership (video_id, owner_device_id, owner_user_id)
SELECT id, owner_device_id, owner_user_id
FROM public.my_videos
WHERE owner_device_id IS NOT NULL
ON CONFLICT (video_id) DO NOTHING;

UPDATE public.my_videos
SET owner_device_id = NULL,
    owner_user_id = NULL
WHERE owner_device_id IS NOT NULL OR owner_user_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.capture_my_video_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NULLIF(BTRIM(NEW.owner_device_id), '') IS NULL
     OR char_length(BTRIM(NEW.owner_device_id)) > 128 THEN
    RAISE EXCEPTION 'A valid owner device is required for a MyVideo.';
  END IF;

  INSERT INTO public.my_video_ownership (video_id, owner_device_id, owner_user_id)
  VALUES (NEW.id, BTRIM(NEW.owner_device_id), NEW.owner_user_id);

  NEW.owner_device_id := NULL;
  NEW.owner_user_id := NULL;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.capture_my_video_owner() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS my_videos_capture_owner ON public.my_videos;
CREATE TRIGGER my_videos_capture_owner
  BEFORE INSERT ON public.my_videos
  FOR EACH ROW EXECUTE FUNCTION public.capture_my_video_owner();

DO $migration$
DECLARE
  v_get_function TEXT;
  v_delete_function TEXT;
BEGIN
  v_get_function := CASE
    WHEN to_regprocedure('public.get_my_video_owned_ids_unlocked(uuid[],text)') IS NOT NULL
      THEN 'public.get_my_video_owned_ids_unlocked'
    ELSE 'public.get_my_video_owned_ids'
  END;

  EXECUTE format($ddl$
    CREATE OR REPLACE FUNCTION %s(p_video_ids UUID[], p_device_id TEXT)
    RETURNS UUID[]
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      v_owned_ids UUID[];
    BEGIN
      IF p_video_ids IS NULL
         OR cardinality(p_video_ids) > 100
         OR NULLIF(BTRIM(p_device_id), '') IS NULL
         OR char_length(BTRIM(p_device_id)) > 128 THEN
        RETURN ARRAY[]::UUID[];
      END IF;

      SELECT COALESCE(array_agg(video_id), ARRAY[]::UUID[])
      INTO v_owned_ids
      FROM public.my_video_ownership
      WHERE video_id = ANY(p_video_ids)
        AND owner_device_id = BTRIM(p_device_id);

      RETURN v_owned_ids;
    END;
    $function$;
  $ddl$, v_get_function);

  v_delete_function := CASE
    WHEN to_regprocedure('public.delete_my_video_unlocked(uuid,text)') IS NOT NULL
      THEN 'public.delete_my_video_unlocked'
    ELSE 'public.delete_my_video'
  END;

  EXECUTE format($ddl$
    CREATE OR REPLACE FUNCTION %s(p_video_id UUID, p_device_id TEXT)
    RETURNS JSONB
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, public
    AS $function$
    DECLARE
      v_deleted_id UUID;
    BEGIN
      IF p_video_id IS NULL
         OR NULLIF(BTRIM(p_device_id), '') IS NULL
         OR char_length(BTRIM(p_device_id)) > 128 THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid post or device.');
      END IF;

      DELETE FROM public.my_video_ownership
      WHERE video_id = p_video_id
        AND owner_device_id = BTRIM(p_device_id)
      RETURNING video_id INTO v_deleted_id;

      IF v_deleted_id IS NULL THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'You can only delete a post from the device that created it.');
      END IF;

      DELETE FROM public.my_videos WHERE id = v_deleted_id;
      RETURN jsonb_build_object('success', TRUE, 'deleted_id', v_deleted_id);
    END;
    $function$;
  $ddl$, v_delete_function);
END;
$migration$;

NOTIFY pgrst, 'reload schema';
