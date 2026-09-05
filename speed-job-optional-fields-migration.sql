-- SPEED JOB: ALLOW OPTIONAL AD FIELDS
-- Review only. This migration has not been executed.
-- It preserves the existing table, action encoding, RPC signatures, and delete RPC.

BEGIN;

-- These fields are optional. NULL represents an empty submitted value.
ALTER TABLE public.speed_job_posts
  ALTER COLUMN job_type DROP NOT NULL,
  ALTER COLUMN location DROP NOT NULL,
  ALTER COLUMN contact_info DROP NOT NULL,
  ALTER COLUMN social_links DROP NOT NULL,
  ALTER COLUMN pay DROP NOT NULL,
  ALTER COLUMN schedule_text DROP NOT NULL,
  ALTER COLUMN pack_need DROP NOT NULL,
  ALTER COLUMN description DROP NOT NULL;

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
  v_job_type TEXT := NULLIF(btrim(p_job_type), '');
  v_social_links TEXT[] := ARRAY(
    SELECT NULLIF(btrim(link), '')
    FROM unnest(COALESCE(p_social_links, ARRAY[]::TEXT[])) AS link
    WHERE NULLIF(btrim(link), '') IS NOT NULL
  );
BEGIN
  -- Technical identity and routing fields remain required.
  IF p_room IS NULL OR btrim(p_room) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Room is required');
  END IF;

  IF p_post_type NOT IN ('worker', 'requester') THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid post type');
  END IF;

  IF p_owner_device_id IS NULL OR btrim(p_owner_device_id) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Owner identity is required');
  END IF;

  -- The existing [action:...] prefix preserves action/category mapping.
  -- The display title after the prefix may be empty.
  IF v_job_type IS NULL OR v_job_type !~ '^\[action:[^\]]+\](\s.*)?$' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Action mapping is required');
  END IF;

  IF p_pack_need IS NOT NULL AND p_pack_need < 1 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Pack/Need must be > 0 when provided');
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
    COALESCE(NULLIF(btrim(p_owner_username), ''), 'Anonymous'),
    COALESCE(NULLIF(btrim(p_owner_avatar), ''), '😎'),
    p_post_type,
    v_job_type,
    NULLIF(btrim(p_location), ''),
    NULLIF(btrim(p_contact_info), ''),
    COALESCE(v_social_links, ARRAY[]::TEXT[]),
    NULLIF(btrim(p_pay), ''),
    NULLIF(btrim(p_schedule_text), ''),
    p_pack_need,
    COALESCE(NULLIF(btrim(p_gender), ''), 'L&P'),
    NULLIF(btrim(p_description), ''),
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
  v_job_type TEXT := NULLIF(btrim(p_job_type), '');
  v_social_links TEXT[] := ARRAY(
    SELECT NULLIF(btrim(link), '')
    FROM unnest(COALESCE(p_social_links, ARRAY[]::TEXT[])) AS link
    WHERE NULLIF(btrim(link), '') IS NOT NULL
  );
BEGIN
  -- Technical identity and routing fields remain required.
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

  IF v_job_type IS NULL OR v_job_type !~ '^\[action:[^\]]+\](\s.*)?$' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Action mapping is required');
  END IF;

  IF p_pack_need IS NOT NULL AND p_pack_need < 1 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Pack/Need must be > 0 when provided');
  END IF;

  UPDATE public.speed_job_posts
  SET
    room = btrim(p_room),
    post_type = p_post_type,
    job_type = v_job_type,
    location = NULLIF(btrim(p_location), ''),
    contact_info = NULLIF(btrim(p_contact_info), ''),
    social_links = COALESCE(v_social_links, ARRAY[]::TEXT[]),
    pay = NULLIF(btrim(p_pay), ''),
    schedule_text = NULLIF(btrim(p_schedule_text), ''),
    pack_need = p_pack_need,
    gender = COALESCE(NULLIF(btrim(p_gender), ''), 'L&P'),
    description = NULLIF(btrim(p_description), ''),
    status = 'PENDING',
    owner_username = COALESCE(NULLIF(btrim(p_owner_username), ''), owner_username),
    owner_avatar = COALESCE(NULLIF(btrim(p_owner_avatar), ''), owner_avatar),
    updated_at = NOW()
  WHERE id = p_id AND owner_device_id = btrim(p_owner_device_id);

  RETURN jsonb_build_object(
    'success', TRUE,
    'id', p_id,
    'message', 'Public job updated successfully'
  );
END;
$$;

COMMIT;

-- This file only defines the migration. It has not been executed.
