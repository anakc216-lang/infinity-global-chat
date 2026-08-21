-- PROFILE CROSS-DEVICE MIGRATION
-- Run after supabase-migrations-FIXED.sql.
-- This migration keeps legacy device-based rows for reference, but all new
-- authenticated profiles are owned by auth.users.id through user_id.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS user_id UUID;

ALTER TABLE public.profiles
  ALTER COLUMN device_id DROP NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'profiles_user_id_key'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_user_id_key UNIQUE (user_id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_profiles_user_id
  ON public.profiles(user_id);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow read all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Allow read own profile" ON public.profiles;
DROP POLICY IF EXISTS "Prevent direct profile inserts" ON public.profiles;
DROP POLICY IF EXISTS "Prevent direct profile updates" ON public.profiles;
DROP POLICY IF EXISTS "Prevent profile deletes" ON public.profiles;

CREATE POLICY "Users read own profile"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY "Users insert own profile"
  ON public.profiles FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users update own profile"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "Users delete own profile"
  ON public.profiles FOR DELETE
  TO authenticated
  USING (user_id = auth.uid());

DROP FUNCTION IF EXISTS public.upsert_profile(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS public.get_profile(TEXT);

CREATE OR REPLACE FUNCTION public.upsert_profile(
  p_username TEXT,
  p_avatar TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Authentication required');
  END IF;

  IF p_username IS NULL OR btrim(p_username) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Username cannot be empty');
  END IF;

  IF p_avatar IS NULL OR btrim(p_avatar) = '' THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Avatar cannot be empty');
  END IF;

  p_username := substring(btrim(p_username) FROM 1 FOR 20);

  INSERT INTO public.profiles (user_id, device_id, username, avatar, created_at, updated_at)
  VALUES (v_user_id, NULL, p_username, p_avatar, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
  ON CONFLICT (user_id) DO UPDATE
  SET username = EXCLUDED.username,
      avatar = EXCLUDED.avatar,
      updated_at = CURRENT_TIMESTAMP
  RETURNING id INTO v_profile_id;

  RETURN jsonb_build_object(
    'success', TRUE,
    'profile_id', v_profile_id,
    'user_id', v_user_id,
    'username', p_username,
    'avatar', p_avatar,
    'updated_at', CURRENT_TIMESTAMP
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_profile()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile RECORD;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'profile', NULL, 'error', 'Authentication required');
  END IF;

  SELECT id, user_id, username, avatar, created_at, updated_at
  INTO v_profile
  FROM public.profiles
  WHERE user_id = v_user_id
  LIMIT 1;

  IF v_profile IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'profile', NULL);
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'profile', jsonb_build_object(
      'id', v_profile.id,
      'user_id', v_profile.user_id,
      'username', v_profile.username,
      'avatar', v_profile.avatar,
      'created_at', v_profile.created_at,
      'updated_at', v_profile.updated_at
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_profile(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_profile() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_profile(TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_profile() TO authenticated;
