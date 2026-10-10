-- Public link-only MyVideos feed.
-- Run this migration once in the Supabase SQL Editor.

CREATE TABLE IF NOT EXISTS public.my_videos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
  video_url TEXT NOT NULL CHECK (char_length(video_url) <= 2000),
  provider TEXT NOT NULL CONSTRAINT my_videos_provider_check CHECK (provider IN ('youtube', 'tiktok', 'image', 'external')),
  video_format TEXT NOT NULL CHECK (video_format IN ('short', 'long')),
  username TEXT NOT NULL CHECK (char_length(btrim(username)) BETWEEN 1 AND 80),
  owner_device_id TEXT NOT NULL,
  owner_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  is_hidden BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT my_videos_provider_url_valid CHECK (
    (
      provider = 'youtube'
      AND video_url ~* '^https://(www\.)?(youtube\.com/(watch\?v=[A-Za-z0-9_-]{11}(&[A-Za-z0-9_=&%-]*)?|shorts/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?|embed/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?)|youtu\.be/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?)$'
    )
    OR
    (
      provider = 'tiktok'
      AND video_url ~* '^https://(www\.)?tiktok\.com/@[A-Za-z0-9._]+/video/[0-9]+([?#][^[:space:]]*)?$'
    )
    OR
    (
      provider = 'image'
      AND video_url ~* '^https://([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:[0-9]+)?/[^[:space:]?#]*\.(jpg|jpeg|png|gif|webp|avif)([?#][^[:space:]]*)?$'
    )
    OR
    (
      provider = 'external'
      AND video_url ~* '^https?://[^/@[:space:]?#]+(/[^[:space:]#]*)?([?#][^[:space:]]*)?$'
    )
  )
);

ALTER TABLE public.my_videos
  ADD COLUMN IF NOT EXISTS likes_count INTEGER NOT NULL DEFAULT 0
  CHECK (likes_count >= 0);

ALTER TABLE public.my_videos
  DROP CONSTRAINT IF EXISTS my_videos_provider_check,
  ADD CONSTRAINT my_videos_provider_check CHECK (provider IN ('youtube', 'tiktok', 'image', 'external'));

ALTER TABLE public.my_videos
  DROP CONSTRAINT IF EXISTS my_videos_provider_url_valid;

ALTER TABLE public.my_videos
  ADD CONSTRAINT my_videos_provider_url_valid CHECK (
    (
      provider = 'youtube'
      AND video_url ~* '^https://(www\.)?(youtube\.com/(watch\?v=[A-Za-z0-9_-]{11}(&[A-Za-z0-9_=&%-]*)?|shorts/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?|embed/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?)|youtu\.be/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?)$'
    )
    OR
    (
      provider = 'tiktok'
      AND video_url ~* '^https://(www\.)?tiktok\.com/@[A-Za-z0-9._]+/video/[0-9]+([?#][^[:space:]]*)?$'
    )
    OR
    (
      provider = 'image'
      AND video_url ~* '^https://([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:[0-9]+)?/[^[:space:]?#]*\.(jpg|jpeg|png|gif|webp|avif)([?#][^[:space:]]*)?$'
    )
    OR
    (
      provider = 'external'
      AND video_url ~* '^https?://[^/@[:space:]?#]+(/[^[:space:]#]*)?([?#][^[:space:]]*)?$'
    )
  );

CREATE INDEX IF NOT EXISTS idx_my_videos_public_created
  ON public.my_videos (created_at DESC)
  WHERE is_hidden = FALSE;

CREATE INDEX IF NOT EXISTS idx_my_videos_device_created
  ON public.my_videos (owner_device_id, created_at DESC);

ALTER TABLE public.my_videos ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
REVOKE ALL ON TABLE public.my_videos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.my_videos TO anon, authenticated;

DROP POLICY IF EXISTS "MyVideos public read visible" ON public.my_videos;
CREATE POLICY "MyVideos public read visible"
  ON public.my_videos FOR SELECT
  TO anon, authenticated
  USING (is_hidden = FALSE);

CREATE TABLE IF NOT EXISTS public.my_video_likes (
  video_id UUID NOT NULL REFERENCES public.my_videos(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL CHECK (char_length(btrim(device_id)) BETWEEN 1 AND 128),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (video_id, device_id)
);

ALTER TABLE public.my_video_likes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.my_video_likes FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_my_video(
  p_device_id TEXT,
  p_username TEXT,
  p_title TEXT,
  p_video_url TEXT,
  p_video_format TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_identity TEXT;
  v_recent_count INTEGER;
  v_video public.my_videos;
  v_provider TEXT;
BEGIN
  IF NULLIF(BTRIM(p_device_id), '') IS NULL
     OR char_length(BTRIM(p_device_id)) > 128
     OR NULLIF(BTRIM(p_username), '') IS NULL
     OR NULLIF(BTRIM(p_title), '') IS NULL
     OR char_length(BTRIM(p_title)) > 120
     OR p_video_format IS NULL
     OR p_video_format NOT IN ('short', 'long')
     OR p_video_url IS NULL
     OR char_length(p_video_url) > 2000 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Please check the title, link, and video format.');
  END IF;

  IF p_video_url ~* '^https://(www\.)?(youtube\.com/(watch\?v=[A-Za-z0-9_-]{11}(&[A-Za-z0-9_=&%-]*)?|shorts/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?|embed/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?)|youtu\.be/[A-Za-z0-9_-]{11}([?#][^[:space:]]*)?)$' THEN
    v_provider := 'youtube';
  ELSIF p_video_url ~* '^https://(www\.)?tiktok\.com/@[A-Za-z0-9._]+/video/[0-9]+([?#][^[:space:]]*)?$' THEN
    v_provider := 'tiktok';
  ELSIF p_video_url ~* '^https://([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:[0-9]+)?/[^[:space:]?#]*\.(jpg|jpeg|png|gif|webp|avif)([?#][^[:space:]]*)?$' THEN
    v_provider := 'image';
  ELSIF p_video_url ~* '^https?://[^/@[:space:]?#]+(/[^[:space:]#]*)?([?#][^[:space:]]*)?$' THEN
    v_provider := 'external';
  ELSE
    RETURN jsonb_build_object('success', FALSE, 'error', 'Enter a valid public HTTP or HTTPS link.');
  END IF;

  v_identity := COALESCE(auth.uid()::TEXT, BTRIM(p_device_id));
  PERFORM pg_advisory_xact_lock(hashtextextended(v_identity, 0));

  SELECT count(*) INTO v_recent_count
  FROM public.my_videos
  WHERE created_at > NOW() - INTERVAL '1 hour'
    AND (
      (auth.uid() IS NOT NULL AND owner_user_id = auth.uid())
      OR
      (auth.uid() IS NULL AND owner_device_id = BTRIM(p_device_id))
    );

  IF v_recent_count >= 5 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'You can post up to 5 videos per hour.');
  END IF;

  INSERT INTO public.my_videos (
    title, video_url, provider, video_format, username, owner_device_id, owner_user_id
  )
  VALUES (
    BTRIM(p_title),
    BTRIM(p_video_url),
    v_provider,
    p_video_format,
    LEFT(BTRIM(p_username), 80),
    BTRIM(p_device_id),
    auth.uid()
  )
  RETURNING * INTO v_video;

  RETURN jsonb_build_object('success', TRUE, 'video', to_jsonb(v_video));
END;
$$;

REVOKE ALL ON FUNCTION public.create_my_video(TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_my_video(TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_my_video_owned_ids(
  p_video_ids UUID[],
  p_device_id TEXT
)
RETURNS UUID[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_owned_ids UUID[];
BEGIN
  IF p_video_ids IS NULL
     OR cardinality(p_video_ids) > 100
     OR NULLIF(BTRIM(p_device_id), '') IS NULL
     OR char_length(BTRIM(p_device_id)) > 128 THEN
    RETURN ARRAY[]::UUID[];
  END IF;

  SELECT COALESCE(array_agg(id), ARRAY[]::UUID[])
  INTO v_owned_ids
  FROM public.my_videos
  WHERE id = ANY(p_video_ids)
    AND (
      (auth.uid() IS NOT NULL AND (
        owner_user_id = auth.uid()
        OR (owner_user_id IS NULL AND owner_device_id = BTRIM(p_device_id))
      ))
      OR
      (auth.uid() IS NULL AND owner_user_id IS NULL AND owner_device_id = BTRIM(p_device_id))
    );

  RETURN v_owned_ids;
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_video_owned_ids(UUID[], TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_video_owned_ids(UUID[], TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.delete_my_video(
  p_video_id UUID,
  p_device_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_deleted_id UUID;
BEGIN
  IF p_video_id IS NULL
     OR NULLIF(BTRIM(p_device_id), '') IS NULL
     OR char_length(BTRIM(p_device_id)) > 128 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid post or device.');
  END IF;

  DELETE FROM public.my_videos
  WHERE id = p_video_id
    AND (
      (auth.uid() IS NOT NULL AND (
        owner_user_id = auth.uid()
        OR (owner_user_id IS NULL AND owner_device_id = BTRIM(p_device_id))
      ))
      OR
      (auth.uid() IS NULL AND owner_user_id IS NULL AND owner_device_id = BTRIM(p_device_id))
    )
  RETURNING id INTO v_deleted_id;

  IF v_deleted_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'You can only delete a post you created.');
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'deleted_id', v_deleted_id);
END;
$$;

REVOKE ALL ON FUNCTION public.delete_my_video(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_my_video(UUID, TEXT) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.toggle_my_video_like(
  p_video_id UUID,
  p_device_id TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_hidden BOOLEAN;
  v_liked BOOLEAN;
  v_likes_count INTEGER;
BEGIN
  IF p_video_id IS NULL
     OR NULLIF(BTRIM(p_device_id), '') IS NULL
     OR char_length(BTRIM(p_device_id)) > 128 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid post or device.');
  END IF;

  SELECT is_hidden INTO v_hidden
  FROM public.my_videos
  WHERE id = p_video_id
  FOR UPDATE;

  IF NOT FOUND OR v_hidden THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'This post is unavailable.');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.my_video_likes
    WHERE video_id = p_video_id
      AND device_id = BTRIM(p_device_id)
  ) INTO v_liked;

  IF v_liked THEN
    DELETE FROM public.my_video_likes
    WHERE video_id = p_video_id
      AND device_id = BTRIM(p_device_id);
    v_liked := FALSE;
  ELSE
    INSERT INTO public.my_video_likes (video_id, device_id)
    VALUES (p_video_id, BTRIM(p_device_id));
    v_liked := TRUE;
  END IF;

  UPDATE public.my_videos
  SET likes_count = (
    SELECT count(*)::INTEGER
    FROM public.my_video_likes
    WHERE video_id = p_video_id
  )
  WHERE id = p_video_id
  RETURNING likes_count INTO v_likes_count;

  RETURN jsonb_build_object(
    'success', TRUE,
    'liked', v_liked,
    'likes_count', v_likes_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.toggle_my_video_like(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.toggle_my_video_like(UUID, TEXT) TO anon, authenticated;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.my_videos;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END;
$$;

NOTIFY pgrst, 'reload schema';
