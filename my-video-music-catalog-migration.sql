-- Public MyVideos music catalog using external audio links only.
-- Audio files are never uploaded to Supabase Storage or stored in PostgreSQL.
-- Removing a public link in the app only hides it on that device; this catalog has no public delete RPC.
-- Run this entire file in the Supabase SQL Editor.

CREATE TABLE IF NOT EXISTS public.my_video_music_links (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 120),
  audio_url TEXT NOT NULL UNIQUE CHECK (char_length(audio_url) <= 2000),
  username TEXT NOT NULL CHECK (char_length(btrim(username)) BETWEEN 1 AND 80),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT my_video_music_audio_url_valid CHECK (
    audio_url ~* '^https://[^/@[:space:]?#]+/[^[:space:]#]+\.(mp3|m4a|aac|wav|ogg|opus|flac|webm|mp4)([?#][^[:space:]]*)?$'
  )
);

DROP FUNCTION IF EXISTS public.delete_my_video_music_link(UUID, TEXT);
DROP FUNCTION IF EXISTS public.get_my_video_music_owned_ids(UUID[], TEXT);
DROP FUNCTION IF EXISTS public.create_my_video_music_link(TEXT, TEXT, TEXT, TEXT, BOOLEAN);
DROP TABLE IF EXISTS public.my_video_music_link_owners;

CREATE INDEX IF NOT EXISTS idx_my_video_music_links_created
  ON public.my_video_music_links (created_at DESC, id DESC);

ALTER TABLE public.my_video_music_links ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
REVOKE ALL ON TABLE public.my_video_music_links FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.my_video_music_links TO anon, authenticated;

DROP POLICY IF EXISTS "Public audio links are readable" ON public.my_video_music_links;
CREATE POLICY "Public audio links are readable"
  ON public.my_video_music_links FOR SELECT
  TO anon, authenticated
  USING (TRUE);

CREATE OR REPLACE FUNCTION public.create_my_video_music_link(
  p_username TEXT,
  p_title TEXT,
  p_audio_url TEXT,
  p_rights_confirmed BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_track public.my_video_music_links;
  v_catalog_count BIGINT;
BEGIN
  IF NULLIF(BTRIM(p_username), '') IS NULL
     OR char_length(BTRIM(p_username)) > 80
     OR NULLIF(BTRIM(p_title), '') IS NULL
     OR char_length(BTRIM(p_title)) > 120
     OR p_audio_url IS NULL
     OR char_length(BTRIM(p_audio_url)) > 2000
     OR p_rights_confirmed IS DISTINCT FROM TRUE THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Please check the title, audio link, and sharing rights confirmation.');
  END IF;

  IF BTRIM(p_audio_url) !~* '^https://[^/@[:space:]?#]+/[^[:space:]#]+\.(mp3|m4a|aac|wav|ogg|opus|flac|webm|mp4)([?#][^[:space:]]*)?$' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Use a direct HTTPS link to a supported audio file.');
  END IF;

  PERFORM pg_advisory_xact_lock(807314927);
  SELECT count(*) INTO v_catalog_count
  FROM public.my_video_music_links;
  IF v_catalog_count >= 10000 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'The public music catalog is full (10,000 links).');
  END IF;

  INSERT INTO public.my_video_music_links (title, audio_url, username)
  VALUES (BTRIM(p_title), BTRIM(p_audio_url), LEFT(BTRIM(p_username), 80))
  RETURNING * INTO v_track;

  RETURN jsonb_build_object(
    'success', TRUE,
    'track', jsonb_build_object(
      'id', v_track.id,
      'title', v_track.title,
      'audio_url', v_track.audio_url,
      'username', v_track.username,
      'created_at', v_track.created_at
    )
  );
EXCEPTION
  WHEN unique_violation THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'This audio link is already in the public catalog.');
END;
$$;

REVOKE ALL ON FUNCTION public.create_my_video_music_link(TEXT, TEXT, TEXT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_my_video_music_link(TEXT, TEXT, TEXT, BOOLEAN) TO anon, authenticated;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.my_video_music_links;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END;
$$;

NOTIFY pgrst, 'reload schema';
