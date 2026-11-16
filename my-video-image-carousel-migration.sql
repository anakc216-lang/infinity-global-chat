-- Add multi-image carousel posts to MyVideos.
-- Run after my-video-playlists-migration.sql.

ALTER TABLE public.my_videos
  ADD COLUMN IF NOT EXISTS image_urls JSONB NOT NULL DEFAULT '[]'::JSONB;

UPDATE public.my_videos
SET image_urls = '[]'::JSONB
WHERE image_urls IS NULL;

ALTER TABLE public.my_videos
  ALTER COLUMN image_urls SET DEFAULT '[]'::JSONB,
  ALTER COLUMN image_urls SET NOT NULL;

ALTER TABLE public.my_videos
  DROP CONSTRAINT IF EXISTS my_videos_image_urls_array_check,
  ADD CONSTRAINT my_videos_image_urls_array_check
    CHECK (jsonb_typeof(image_urls) = 'array');

CREATE OR REPLACE FUNCTION public.create_my_video_image_carousel(
  p_device_id TEXT,
  p_username TEXT,
  p_video_urls TEXT[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_video public.my_videos;
BEGIN
  IF NULLIF(BTRIM(p_device_id), '') IS NULL
     OR char_length(BTRIM(p_device_id)) > 128
     OR NULLIF(BTRIM(p_username), '') IS NULL
     OR p_video_urls IS NULL
     OR cardinality(p_video_urls) < 2 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'A carousel needs at least two valid image links.');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_video_urls) AS links(video_url)
    WHERE NULLIF(BTRIM(video_url), '') IS NULL
       OR char_length(BTRIM(video_url)) > 2000
       OR BTRIM(video_url) !~* '^https://([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:[0-9]+)?/[^[:space:]?#]*\.(jpg|jpeg|png|gif|webp|avif)([?#][^[:space:]]*)?$'
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Every carousel link must be a public HTTPS image link.');
  END IF;

  INSERT INTO public.my_videos (
    title, video_url, image_urls, provider, video_format, username, owner_device_id, owner_user_id
  )
  VALUES (
    'Image',
    BTRIM(p_video_urls[1]),
    to_jsonb(ARRAY(SELECT BTRIM(url) FROM unnest(p_video_urls) WITH ORDINALITY AS links(url, ordinality) ORDER BY ordinality)),
    'image',
    'long',
    LEFT(BTRIM(p_username), 80),
    BTRIM(p_device_id),
    auth.uid()
  )
  RETURNING * INTO v_video;

  RETURN jsonb_build_object('success', TRUE, 'video', to_jsonb(v_video));
END;
$$;

CREATE OR REPLACE FUNCTION public.update_my_video_image_carousel(
  p_video_id UUID,
  p_device_id TEXT,
  p_video_urls TEXT[]
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_video public.my_videos;
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'AUTH_OR_PRO_ACCESS_REQUIRED');
  END IF;
  IF p_video_id IS NULL
     OR NULLIF(BTRIM(p_device_id), '') IS NULL
     OR char_length(BTRIM(p_device_id)) > 128
     OR p_video_urls IS NULL
     OR cardinality(p_video_urls) < 1 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Add at least one valid image link.');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_video_urls) AS links(video_url)
    WHERE NULLIF(BTRIM(video_url), '') IS NULL
       OR char_length(BTRIM(video_url)) > 2000
       OR BTRIM(video_url) !~* '^https://([A-Za-z0-9-]+\.)+[A-Za-z]{2,}(:[0-9]+)?/[^[:space:]?#]*\.(jpg|jpeg|png|gif|webp|avif)([?#][^[:space:]]*)?$'
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Every carousel link must be a public HTTPS image link.');
  END IF;

  UPDATE public.my_videos AS v
  SET title = 'Image',
      video_url = BTRIM(p_video_urls[1]),
      image_urls = CASE
        WHEN cardinality(p_video_urls) > 1 THEN
          to_jsonb(ARRAY(SELECT BTRIM(url) FROM unnest(p_video_urls) WITH ORDINALITY AS links(url, ordinality) ORDER BY ordinality))
        ELSE '[]'::JSONB
      END,
      provider = 'image',
      video_format = 'long'
  FROM public.my_video_ownership AS o
  WHERE v.id = p_video_id
    AND o.video_id = v.id
    AND o.owner_device_id = BTRIM(p_device_id)
  RETURNING v.* INTO v_video;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'You can only edit a post from the device that created it.');
  END IF;
  RETURN jsonb_build_object('success', TRUE, 'video', to_jsonb(v_video));
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_video_playlist_items(p_playlist_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_items JSONB;
BEGIN
  IF p_playlist_id IS NULL OR NOT public.my_video_playlist_access_allowed()
     OR NOT EXISTS (
       SELECT 1
       FROM public.my_video_playlists
       WHERE id = p_playlist_id
         AND owner_user_id = auth.uid()
     ) THEN
    RETURN '[]'::JSONB;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', v.id,
        'title', v.title,
        'video_url', v.video_url,
        'image_urls', v.image_urls,
        'video_format', v.video_format,
        'username', v.username,
        'created_at', v.created_at,
        'likes_count', v.likes_count
      )
      ORDER BY i.added_at DESC
    ),
    '[]'::JSONB
  )
  INTO v_items
  FROM public.my_video_playlist_items AS i
  JOIN public.my_videos AS v ON v.id = i.video_id
  WHERE i.playlist_id = p_playlist_id
    AND v.is_hidden = FALSE;

  RETURN v_items;
END;
$$;

REVOKE ALL ON FUNCTION public.create_my_video_image_carousel(TEXT, TEXT, TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_my_video_image_carousel(UUID, TEXT, TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_video_playlist_items(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_my_video_image_carousel(TEXT, TEXT, TEXT[]) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_my_video_image_carousel(UUID, TEXT, TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_video_playlist_items(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
