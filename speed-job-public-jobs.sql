-- =============================================================
-- SPEED JOB PUBLIC JOBS - REQUIRED SUPABASE SQL
-- Run this in Supabase SQL Editor.
-- This is the source-of-truth database layer for persistent public jobs.
-- =============================================================

DROP TABLE IF EXISTS public.speed_job_posts CASCADE;

DROP FUNCTION IF EXISTS public.get_speed_job_posts(TEXT);
DROP FUNCTION IF EXISTS public.create_speed_job_post(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.delete_speed_job_post(UUID, TEXT);

CREATE TABLE public.speed_job_posts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  room TEXT NOT NULL,
  owner_device_id TEXT NOT NULL,
  owner_username TEXT NOT NULL,
  owner_avatar TEXT NOT NULL DEFAULT '😎',
  post_type TEXT NOT NULL CHECK (post_type IN ('worker', 'requester')),
  job_type TEXT NOT NULL,
  location TEXT NOT NULL,
  contact_info TEXT NOT NULL,
  social_links TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  pay TEXT NOT NULL,
  schedule_text TEXT NOT NULL,
  pack_need INTEGER NOT NULL CHECK (pack_need > 0),
  gender TEXT NOT NULL DEFAULT 'L&P',
  description TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_speed_job_posts_room_type
  ON public.speed_job_posts (room, post_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_speed_job_posts_owner_device_id
  ON public.speed_job_posts (owner_device_id);

ALTER TABLE public.speed_job_posts ENABLE ROW LEVEL SECURITY;

-- Push new, updated, and deleted public jobs to every connected app.
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.speed_job_posts;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

DROP POLICY IF EXISTS "Speed jobs read public" ON public.speed_job_posts;
CREATE POLICY "Speed jobs read public"
  ON public.speed_job_posts FOR SELECT
  TO anon, authenticated
  USING (TRUE);

DROP POLICY IF EXISTS "Speed jobs insert public" ON public.speed_job_posts;
CREATE POLICY "Speed jobs insert public"
  ON public.speed_job_posts FOR INSERT
  TO anon, authenticated
  WITH CHECK (TRUE);

DROP POLICY IF EXISTS "Speed jobs update owner only" ON public.speed_job_posts;
CREATE POLICY "Speed jobs update owner only"
  ON public.speed_job_posts FOR UPDATE
  TO anon, authenticated
  USING (TRUE)
  WITH CHECK (TRUE);

DROP POLICY IF EXISTS "Speed jobs delete owner only" ON public.speed_job_posts;
CREATE POLICY "Speed jobs delete owner only"
  ON public.speed_job_posts FOR DELETE
  TO anon, authenticated
  USING (TRUE);

CREATE OR REPLACE FUNCTION public.get_speed_job_posts(p_post_type TEXT DEFAULT NULL)
RETURNS TABLE (
  id UUID,
  room TEXT,
  owner_device_id TEXT,
  owner_username TEXT,
  owner_avatar TEXT,
  post_type TEXT,
  job_type TEXT,
  location TEXT,
  contact_info TEXT,
  social_links TEXT[],
  pay TEXT,
  schedule_text TEXT,
  pack_need INTEGER,
  gender TEXT,
  description TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    s.id,
    s.room,
    s.owner_device_id,
    s.owner_username,
    s.owner_avatar,
    s.post_type,
    s.job_type,
    s.location,
    s.contact_info,
    s.social_links,
    s.pay,
    s.schedule_text,
    s.pack_need,
    s.gender,
    s.description,
    s.status,
    s.created_at,
    s.updated_at
  FROM public.speed_job_posts s
  WHERE (p_post_type IS NULL OR s.post_type = p_post_type)
  ORDER BY s.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.create_speed_job_post(
  p_room TEXT,
  p_post_type TEXT,
  p_job_type TEXT,
  p_location TEXT,
  p_contact_info TEXT,
  p_social_links TEXT[],
  p_pay TEXT,
  p_schedule_text TEXT,
  p_pack_need INTEGER,
  p_gender TEXT,
  p_description TEXT,
  p_owner_device_id TEXT,
  p_owner_username TEXT,
  p_owner_avatar TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_id UUID;
  v_social_links TEXT[] := COALESCE(p_social_links, ARRAY[]::TEXT[]);
BEGIN
  IF p_room IS NULL OR btrim(p_room) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Room is required');
  END IF;

  IF p_post_type NOT IN ('worker', 'requester') THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid post type');
  END IF;

  IF p_owner_device_id IS NULL OR btrim(p_owner_device_id) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Owner identity is required');
  END IF;

  IF p_job_type IS NULL OR btrim(p_job_type) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Job type is required');
  END IF;

  IF p_location IS NULL OR btrim(p_location) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Location is required');
  END IF;

  IF p_contact_info IS NULL OR btrim(p_contact_info) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Contact info is required');
  END IF;

  v_social_links := ARRAY(
    SELECT btrim(link)
    FROM unnest(v_social_links) AS link
    WHERE btrim(link) <> ''
  );

  IF p_pay IS NULL OR btrim(p_pay) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Pay is required');
  END IF;

  IF p_schedule_text IS NULL OR btrim(p_schedule_text) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Schedule is required');
  END IF;

  IF p_pack_need IS NULL OR p_pack_need < 1 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Pack/Need must be > 0');
  END IF;

  IF p_description IS NULL OR btrim(p_description) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Description is required');
  END IF;

  INSERT INTO public.speed_job_posts (
    room,
    owner_device_id,
    owner_username,
    owner_avatar,
    post_type,
    job_type,
    location,
    contact_info,
    social_links,
    pay,
    schedule_text,
    pack_need,
    gender,
    description,
    status,
    created_at,
    updated_at
  ) VALUES (
    btrim(p_room),
    btrim(p_owner_device_id),
    COALESCE(btrim(p_owner_username), 'Anonymous'),
    COALESCE(btrim(p_owner_avatar), '😎'),
    p_post_type,
    btrim(p_job_type),
    btrim(p_location),
    btrim(p_contact_info),
    v_social_links,
    btrim(p_pay),
    btrim(p_schedule_text),
    p_pack_need,
    COALESCE(btrim(p_gender), 'L&P'),
    btrim(p_description),
    'PENDING',
    NOW(),
    NOW()
  )
  RETURNING id INTO v_new_id;

  RETURN jsonb_build_object(
    'success', TRUE,
    'id', v_new_id,
    'owner_device_id', btrim(p_owner_device_id),
    'message', 'Public job created successfully'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_speed_job_post(
  p_id UUID,
  p_room TEXT,
  p_post_type TEXT,
  p_job_type TEXT,
  p_location TEXT,
  p_contact_info TEXT,
  p_social_links TEXT[],
  p_pay TEXT,
  p_schedule_text TEXT,
  p_pack_need INTEGER,
  p_gender TEXT,
  p_description TEXT,
  p_owner_device_id TEXT,
  p_owner_username TEXT,
  p_owner_avatar TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
  v_social_links TEXT[] := COALESCE(p_social_links, ARRAY[]::TEXT[]);
BEGIN
  IF p_room IS NULL OR btrim(p_room) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Room is required');
  END IF;

  IF p_owner_device_id IS NULL OR btrim(p_owner_device_id) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Owner identity is required');
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.speed_job_posts
  WHERE id = p_id AND owner_device_id = btrim(p_owner_device_id);

  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'You are not allowed to edit this post');
  END IF;

  IF p_post_type NOT IN ('worker', 'requester') THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid post type');
  END IF;

  IF p_contact_info IS NULL OR btrim(p_contact_info) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Contact info is required');
  END IF;

  v_social_links := ARRAY(
    SELECT btrim(link)
    FROM unnest(v_social_links) AS link
    WHERE btrim(link) <> ''
  );

  UPDATE public.speed_job_posts
  SET
    room = btrim(p_room),
    post_type = p_post_type,
    job_type = btrim(p_job_type),
    location = btrim(p_location),
    contact_info = btrim(p_contact_info),
    social_links = v_social_links,
    pay = btrim(p_pay),
    schedule_text = btrim(p_schedule_text),
    pack_need = p_pack_need,
    gender = COALESCE(btrim(p_gender), 'L&P'),
    description = btrim(p_description),
    status = 'PENDING',
    owner_username = COALESCE(btrim(p_owner_username), owner_username),
    owner_avatar = COALESCE(btrim(p_owner_avatar), owner_avatar),
    updated_at = NOW()
  WHERE id = p_id AND owner_device_id = btrim(p_owner_device_id);

  RETURN jsonb_build_object(
    'success', TRUE,
    'id', p_id,
    'message', 'Public job updated successfully'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_speed_job_post(
  p_id UUID,
  p_owner_device_id TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  IF p_owner_device_id IS NULL OR btrim(p_owner_device_id) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Owner identity is required');
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.speed_job_posts
  WHERE id = p_id AND owner_device_id = btrim(p_owner_device_id);

  IF v_count = 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'You are not allowed to delete this post');
  END IF;

  DELETE FROM public.speed_job_posts
  WHERE id = p_id AND owner_device_id = btrim(p_owner_device_id);

  RETURN jsonb_build_object(
    'success', TRUE,
    'id', p_id,
    'message', 'Public job deleted successfully'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_speed_job_posts(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_speed_job_post(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_speed_job_post(UUID, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_speed_job_posts(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_speed_job_post(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_speed_job_post(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT[], TEXT, TEXT, INTEGER, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_speed_job_post(UUID, TEXT) TO anon, authenticated;

SELECT 'SPEED JOB SQL READY' AS status;
