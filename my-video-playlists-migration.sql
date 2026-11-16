-- Add account-synced playlists and owner-only MyVideo editing.
-- Run after my-video-device-ownership-migration.sql in the Supabase SQL Editor.
-- Run this entire file; do not run a selected section by itself.

CREATE TABLE IF NOT EXISTS public.my_video_playlists (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_my_video_playlists_owner_name
  ON public.my_video_playlists (owner_user_id, lower(name));

CREATE TABLE IF NOT EXISTS public.my_video_playlist_items (
  playlist_id UUID NOT NULL REFERENCES public.my_video_playlists(id) ON DELETE CASCADE,
  video_id UUID NOT NULL REFERENCES public.my_videos(id) ON DELETE CASCADE,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (playlist_id, video_id)
);

CREATE INDEX IF NOT EXISTS idx_my_video_playlist_items_video
  ON public.my_video_playlist_items (video_id);

ALTER TABLE public.my_video_playlists ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.my_video_playlist_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.my_video_playlists FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.my_video_playlist_items FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.my_video_playlist_access_allowed()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_has_access BOOLEAN;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN FALSE;
  END IF;

  IF to_regprocedure('public.has_active_pro_access(uuid)') IS NULL THEN
    RETURN TRUE;
  END IF;

  EXECUTE 'SELECT public.has_active_pro_access($1)'
    INTO v_has_access
    USING auth.uid();
  RETURN COALESCE(v_has_access, FALSE);
END;
$$;

REVOKE ALL ON FUNCTION public.my_video_playlist_access_allowed() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_my_video_playlists()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_playlists JSONB;
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN '[]'::JSONB;
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object('id', id, 'name', name, 'created_at', created_at)
      ORDER BY created_at DESC, id
    ),
    '[]'::JSONB
  )
  INTO v_playlists
  FROM public.my_video_playlists
  WHERE owner_user_id = auth.uid();

  RETURN v_playlists;
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

CREATE OR REPLACE FUNCTION public.create_my_video_playlist(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_playlist public.my_video_playlists;
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'AUTH_OR_PRO_ACCESS_REQUIRED');
  END IF;
  IF NULLIF(BTRIM(p_name), '') IS NULL OR char_length(BTRIM(p_name)) > 60 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Playlist names must be 1 to 60 characters.');
  END IF;

  INSERT INTO public.my_video_playlists (owner_user_id, name)
  VALUES (auth.uid(), BTRIM(p_name))
  RETURNING * INTO v_playlist;

  RETURN jsonb_build_object('success', TRUE, 'playlist', to_jsonb(v_playlist));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'You already have a playlist with that name.');
END;
$$;

CREATE OR REPLACE FUNCTION public.rename_my_video_playlist(p_playlist_id UUID, p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_playlist public.my_video_playlists;
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'AUTH_OR_PRO_ACCESS_REQUIRED');
  END IF;
  IF p_playlist_id IS NULL OR NULLIF(BTRIM(p_name), '') IS NULL OR char_length(BTRIM(p_name)) > 60 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Playlist names must be 1 to 60 characters.');
  END IF;

  UPDATE public.my_video_playlists
  SET name = BTRIM(p_name)
  WHERE id = p_playlist_id
    AND owner_user_id = auth.uid()
  RETURNING * INTO v_playlist;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Playlist not found.');
  END IF;
  RETURN jsonb_build_object('success', TRUE, 'playlist', to_jsonb(v_playlist));
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'You already have a playlist with that name.');
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_my_video_playlist(p_playlist_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'AUTH_OR_PRO_ACCESS_REQUIRED');
  END IF;
  IF p_playlist_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Playlist not found.');
  END IF;

  DELETE FROM public.my_video_playlists
  WHERE id = p_playlist_id
    AND owner_user_id = auth.uid();
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Playlist not found.');
  END IF;
  RETURN jsonb_build_object('success', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.save_my_video_to_playlist(p_playlist_id UUID, p_video_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'AUTH_OR_PRO_ACCESS_REQUIRED');
  END IF;
  IF p_playlist_id IS NULL OR p_video_id IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.my_video_playlists
       WHERE id = p_playlist_id AND owner_user_id = auth.uid()
     ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Playlist not found.');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.my_videos
    WHERE id = p_video_id AND is_hidden = FALSE
  ) THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'This video is unavailable.');
  END IF;

  INSERT INTO public.my_video_playlist_items (playlist_id, video_id)
  VALUES (p_playlist_id, p_video_id)
  ON CONFLICT (playlist_id, video_id) DO NOTHING;

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_my_video_from_playlist(p_playlist_id UUID, p_video_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'AUTH_OR_PRO_ACCESS_REQUIRED');
  END IF;
  IF p_playlist_id IS NULL OR p_video_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid playlist item.');
  END IF;

  DELETE FROM public.my_video_playlist_items AS i
  USING public.my_video_playlists AS p
  WHERE i.playlist_id = p_playlist_id
    AND i.video_id = p_video_id
    AND p.id = i.playlist_id
    AND p.owner_user_id = auth.uid();

  RETURN jsonb_build_object('success', TRUE);
END;
$$;

CREATE OR REPLACE FUNCTION public.update_my_video(
  p_video_id UUID,
  p_device_id TEXT,
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
  v_video public.my_videos;
  v_provider TEXT;
BEGIN
  IF NOT public.my_video_playlist_access_allowed() THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'AUTH_OR_PRO_ACCESS_REQUIRED');
  END IF;
  IF p_video_id IS NULL
     OR NULLIF(BTRIM(p_device_id), '') IS NULL
     OR char_length(BTRIM(p_device_id)) > 128
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

  UPDATE public.my_videos AS v
  SET title = BTRIM(p_title),
      video_url = BTRIM(p_video_url),
      provider = v_provider,
      video_format = p_video_format
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

REVOKE ALL ON FUNCTION public.get_my_video_playlists() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_video_playlist_items(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_my_video_playlist(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rename_my_video_playlist(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_my_video_playlist(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_my_video_to_playlist(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_my_video_from_playlist(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_my_video(UUID, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_video_playlists() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_video_playlist_items(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_my_video_playlist(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rename_my_video_playlist(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_video_playlist(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_my_video_to_playlist(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_my_video_from_playlist(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_my_video(UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
