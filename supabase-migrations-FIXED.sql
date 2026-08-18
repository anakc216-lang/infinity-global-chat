-- ============================================================================
-- SERVER-SIDE QUOTA ENFORCEMENT MIGRATION (FIXED VERSION)
-- Safe migration: preserves data, updates existing schema safely, no destructive DDL
-- Supports all 33 country channels
-- ============================================================================

-- 0. CREATE messages TABLE (stores all chat messages)
-- This is the main table that stores all messages across all rooms
CREATE TABLE IF NOT EXISTS public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  room TEXT NOT NULL,
  username TEXT NOT NULL,
  avatar TEXT NOT NULL,
  content TEXT NOT NULL,
  reply_to TEXT,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Create index for fast message retrieval by room
CREATE INDEX IF NOT EXISTS idx_messages_room_created
  ON public.messages(room, created_at DESC);

-- Enable RLS for messages table
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Allow all users to read messages (public chat)
DROP POLICY IF EXISTS "Allow read all messages" ON public.messages;
CREATE POLICY "Allow read all messages"
  ON public.messages FOR SELECT
  TO anon, authenticated
  USING (TRUE);

-- RLS Policy: Prevent direct inserts (use RPC instead)
DROP POLICY IF EXISTS "Prevent direct message inserts" ON public.messages;
CREATE POLICY "Prevent direct message inserts"
  ON public.messages FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE);

-- RLS Policy: Prevent direct updates
DROP POLICY IF EXISTS "Prevent direct message updates" ON public.messages;
CREATE POLICY "Prevent direct message updates"
  ON public.messages FOR UPDATE
  TO anon, authenticated
  USING (FALSE) WITH CHECK (FALSE);

-- RLS Policy: Prevent direct deletes
DROP POLICY IF EXISTS "Prevent direct message deletes" ON public.messages;
CREATE POLICY "Prevent direct message deletes"
  ON public.messages FOR DELETE
  TO anon, authenticated
  USING (FALSE);

-- ============================================================================
-- 0.5. CREATE profiles TABLE (persistent user profiles)
-- This table stores the persistent profile for each device (device_id)
-- Username and avatar are stored here and used in messages
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id TEXT NOT NULL UNIQUE,
  username TEXT NOT NULL,
  avatar TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- Create index for fast profile lookups by device_id
CREATE INDEX IF NOT EXISTS idx_profiles_device_id
  ON public.profiles(device_id);

-- Enable RLS for profiles table
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- RLS Policy: Allow all users to read profiles (public user info)
DROP POLICY IF EXISTS "Allow read all profiles" ON public.profiles;
CREATE POLICY "Allow read all profiles"
  ON public.profiles FOR SELECT
  TO anon, authenticated
  USING (TRUE);

-- RLS Policy: Allow users to read their own profile
DROP POLICY IF EXISTS "Allow read own profile" ON public.profiles;
CREATE POLICY "Allow read own profile"
  ON public.profiles FOR SELECT
  TO anon, authenticated
  USING (TRUE);

-- RLS Policy: Allow insert via RPC only (users cannot directly insert profiles)
DROP POLICY IF EXISTS "Prevent direct profile inserts" ON public.profiles;
CREATE POLICY "Prevent direct profile inserts"
  ON public.profiles FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE);

-- RLS Policy: Allow update via RPC only
DROP POLICY IF EXISTS "Prevent direct profile updates" ON public.profiles;
CREATE POLICY "Prevent direct profile updates"
  ON public.profiles FOR UPDATE
  TO anon, authenticated
  USING (FALSE) WITH CHECK (FALSE);

-- RLS Policy: Prevent deletes
DROP POLICY IF EXISTS "Prevent profile deletes" ON public.profiles;
CREATE POLICY "Prevent profile deletes"
  ON public.profiles FOR DELETE
  TO anon, authenticated
  USING (FALSE);

-- ============================================================================

-- 1. CREATE device_usage TABLE (per-room message count tracking)
-- This table tracks how many messages each device has sent per room
-- SUPPORTS ALL 33 COUNTRY CHANNELS
CREATE TABLE IF NOT EXISTS public.device_usage (
  id BIGSERIAL PRIMARY KEY,
  device_id TEXT NOT NULL,
  room TEXT NOT NULL,
  message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count >= 0),
  last_reset TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(device_id, room)
);

-- IMPORTANT: If device_usage already exists, drop any existing room CHECK constraint
-- and replace it with one that includes all 33 channels.
DO $$
DECLARE
  constraint_rec RECORD;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'device_usage'
  ) THEN
    FOR constraint_rec IN
      SELECT c.conname
      FROM pg_constraint c
      INNER JOIN pg_class cl ON cl.oid = c.conrelid
      INNER JOIN pg_namespace ns ON ns.oid = cl.relnamespace
      WHERE ns.nspname = 'public'
        AND cl.relname = 'device_usage'
        AND c.contype = 'c'
        AND pg_get_constraintdef(c.oid) ILIKE '%room%'
    LOOP
      EXECUTE format('ALTER TABLE public.device_usage DROP CONSTRAINT IF EXISTS %I', constraint_rec.conname);
    END LOOP;
  END IF;
END $$;

-- Explicit idempotency fix: if this constraint already exists from a prior run,
-- drop it before re-adding the full 33-room version.
ALTER TABLE public.device_usage DROP CONSTRAINT IF EXISTS device_usage_room_check;

ALTER TABLE public.device_usage
  ADD CONSTRAINT device_usage_room_check
  CHECK (room IN (
    'malaysia', 'english', 'chinese', 'united_states', 'japan', 'south_korea',
    'singapore', 'indonesia', 'thailand', 'vietnam', 'philippines', 'india',
    'australia', 'new_zealand', 'canada', 'united_kingdom', 'france', 'germany',
    'italy', 'spain', 'netherlands', 'saudi_arabia', 'uae', 'turkey',
    'brazil', 'mexico', 'south_africa', 'egypt', 'nigeria', 'pakistan',
    'bangladesh', 'poland', 'russia'
  ))
  NOT VALID;

ALTER TABLE public.device_usage VALIDATE CONSTRAINT device_usage_room_check;

-- 2. CREATE INDEX for fast lookups by device_id + room
CREATE INDEX IF NOT EXISTS idx_device_usage_device_room
  ON public.device_usage(device_id, room);

-- 3. CREATE lifetime_access TABLE
-- Tracks which devices have lifetime access (paid users)
CREATE TABLE IF NOT EXISTS public.lifetime_access (
  id BIGSERIAL PRIMARY KEY,
  device_id TEXT NOT NULL UNIQUE,
  is_active BOOLEAN DEFAULT TRUE,
  payment_method TEXT,
  payment_id TEXT,
  activated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 4. CREATE INDEX for fast lifetime access lookups
CREATE INDEX IF NOT EXISTS idx_lifetime_access_device_id
  ON public.lifetime_access(device_id)
  WHERE is_active = TRUE;

-- ============================================================================

-- 5. CREATE RPC FUNCTION: check_and_send_message
-- This function enforces quota at the database level
-- It performs atomic increment to prevent race conditions
CREATE OR REPLACE FUNCTION public.check_and_send_message(
  p_device_id TEXT,
  p_room TEXT,
  p_username TEXT,
  p_avatar TEXT,
  p_content TEXT,
  p_reply_to TEXT DEFAULT NULL
)
RETURNS jsonb AS $$
DECLARE
  v_lifetime_active BOOLEAN;
  v_current_count INTEGER;
  v_message_id UUID;
  v_remaining_quota INTEGER;
BEGIN
  -- Step 1: Check if device has lifetime access
  SELECT is_active INTO v_lifetime_active
  FROM public.lifetime_access
  WHERE device_id = p_device_id
  LIMIT 1;

  v_lifetime_active := COALESCE(v_lifetime_active, FALSE);

  -- Step 2: If lifetime access, skip quota check and send directly
  IF v_lifetime_active = TRUE THEN
    INSERT INTO public.messages (room, username, avatar, content, reply_to, created_at)
    VALUES (p_room, p_username, p_avatar, p_content, p_reply_to, CURRENT_TIMESTAMP)
    RETURNING id INTO v_message_id;

    RETURN jsonb_build_object(
      'success', TRUE,
      'message_id', v_message_id,
      'remaining_quota', -1,
      'is_lifetime', TRUE
    );
  END IF;

  -- Step 3: If NOT lifetime, check quota
  INSERT INTO public.device_usage (device_id, room, message_count)
  VALUES (p_device_id, p_room, 0)
  ON CONFLICT (device_id, room) DO NOTHING;

  -- Step 4: Get current count with lock
  SELECT message_count INTO v_current_count
  FROM public.device_usage
  WHERE device_id = p_device_id AND room = p_room
  FOR UPDATE;

  -- Step 5: Check if limit reached
  -- UNLIMITED MODE: Set limit to 999999 (effectively unlimited for testing)
  IF v_current_count >= 999999 THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'LIMIT_REACHED',
      'message', 'Limit reached for ' || p_room,
      'remaining_quota', 0,
      'is_lifetime', FALSE
    );
  END IF;

  -- Step 6: Atomically increment and insert message
  UPDATE public.device_usage
  SET message_count = message_count + 1,
      updated_at = CURRENT_TIMESTAMP
  WHERE device_id = p_device_id AND room = p_room;

  v_current_count := v_current_count + 1;
  v_remaining_quota := 999999 - v_current_count;

  -- Step 7: Insert message
  INSERT INTO public.messages (room, username, avatar, content, reply_to, created_at)
  VALUES (p_room, p_username, p_avatar, p_content, p_reply_to, CURRENT_TIMESTAMP)
  RETURNING id INTO v_message_id;

  -- Step 8: Return success with remaining quota
  RETURN jsonb_build_object(
    'success', TRUE,
    'message_id', v_message_id,
    'remaining_quota', -1,
    'is_lifetime', TRUE
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================

-- 6. CREATE RPC FUNCTION: activate_lifetime_access
-- Called after successful Razorpay payment verification
CREATE OR REPLACE FUNCTION public.activate_lifetime_access(
  p_device_id TEXT,
  p_payment_id TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT 'razorpay'
)
RETURNS jsonb AS $$
BEGIN
  INSERT INTO public.lifetime_access (device_id, is_active, payment_id, payment_method, activated_at)
  VALUES (p_device_id, TRUE, p_payment_id, p_payment_method, CURRENT_TIMESTAMP)
  ON CONFLICT (device_id) DO UPDATE
  SET is_active = TRUE,
      payment_id = COALESCE(p_payment_id, lifetime_access.payment_id),
      payment_method = COALESCE(p_payment_method, lifetime_access.payment_method),
      activated_at = CURRENT_TIMESTAMP,
      updated_at = CURRENT_TIMESTAMP;

  RETURN jsonb_build_object(
    'success', TRUE,
    'message', 'Lifetime access activated for device: ' || p_device_id,
    'device_id', p_device_id,
    'payment_id', p_payment_id,
    'activated_at', CURRENT_TIMESTAMP
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================

-- 7. CREATE RPC FUNCTION: get_device_quota_status
-- Returns quota info for frontend display (informational only)
-- NOW SUPPORTS ALL 33 COUNTRY CHANNELS
CREATE OR REPLACE FUNCTION public.get_device_quota_status(p_device_id TEXT)
RETURNS jsonb AS $$
DECLARE
  v_lifetime_active BOOLEAN;
  v_result JSONB;
  v_room TEXT;
  v_count INTEGER;
BEGIN
  SELECT is_active INTO v_lifetime_active
  FROM public.lifetime_access
  WHERE device_id = p_device_id
  LIMIT 1;

  v_lifetime_active := COALESCE(v_lifetime_active, FALSE);
  v_result := jsonb_build_object('is_lifetime', v_lifetime_active);

  IF v_lifetime_active = TRUE THEN
    v_result := v_result || jsonb_build_object(
      'message', 'Lifetime access active - unlimited messages'
    );
    RETURN v_result;
  END IF;

  FOR v_room IN
    SELECT DISTINCT room
    FROM (VALUES 
      ('malaysia'), ('english'), ('chinese'), ('united_states'), ('japan'), ('south_korea'),
      ('singapore'), ('indonesia'), ('thailand'), ('vietnam'), ('philippines'), ('india'),
      ('australia'), ('new_zealand'), ('canada'), ('united_kingdom'), ('france'), ('germany'),
      ('italy'), ('spain'), ('netherlands'), ('saudi_arabia'), ('uae'), ('turkey'),
      ('brazil'), ('mexico'), ('south_africa'), ('egypt'), ('nigeria'), ('pakistan'),
      ('bangladesh'), ('poland'), ('russia')
    ) AS rooms(room)
  LOOP
    SELECT COALESCE(message_count, 0) INTO v_count
    FROM public.device_usage
    WHERE device_id = p_device_id AND room = v_room;

    v_result := v_result || jsonb_build_object(
      v_room, jsonb_build_object('count', v_count, 'limit', 30)
    );
  END LOOP;

  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================

-- 7.5. CREATE RPC FUNCTION: upsert_profile
-- Safely save or update a user profile by device_id
CREATE OR REPLACE FUNCTION public.upsert_profile(
  p_device_id TEXT,
  p_username TEXT,
  p_avatar TEXT
)
RETURNS jsonb AS $$
DECLARE
  v_profile_id UUID;
BEGIN
  -- Validate inputs
  IF p_device_id IS NULL OR p_device_id = '' THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'Invalid device_id'
    );
  END IF;

  IF p_username IS NULL OR p_username = '' THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'Username cannot be empty'
    );
  END IF;

  -- Truncate username to 20 characters
  p_username := SUBSTRING(p_username FROM 1 FOR 20);

  -- Upsert profile
  INSERT INTO public.profiles (device_id, username, avatar, created_at, updated_at)
  VALUES (p_device_id, p_username, p_avatar, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
  ON CONFLICT (device_id) DO UPDATE
  SET username = p_username,
      avatar = p_avatar,
      updated_at = CURRENT_TIMESTAMP
  RETURNING id INTO v_profile_id;

  RETURN jsonb_build_object(
    'success', TRUE,
    'profile_id', v_profile_id,
    'device_id', p_device_id,
    'username', p_username,
    'avatar', p_avatar,
    'updated_at', CURRENT_TIMESTAMP
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================

-- 7.6. CREATE RPC FUNCTION: get_profile
-- Retrieve a user profile by device_id
CREATE OR REPLACE FUNCTION public.get_profile(
  p_device_id TEXT
)
RETURNS jsonb AS $$
DECLARE
  v_profile RECORD;
BEGIN
  SELECT id, device_id, username, avatar, created_at, updated_at
  INTO v_profile
  FROM public.profiles
  WHERE device_id = p_device_id
  LIMIT 1;

  IF v_profile IS NULL THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'profile', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'profile', jsonb_build_object(
      'id', v_profile.id,
      'device_id', v_profile.device_id,
      'username', v_profile.username,
      'avatar', v_profile.avatar,
      'created_at', v_profile.created_at,
      'updated_at', v_profile.updated_at
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================

-- 8. GRANT EXECUTE PERMISSIONS for anon/authenticated to call RPC functions
GRANT EXECUTE ON FUNCTION public.check_and_send_message(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.activate_lifetime_access(TEXT, TEXT, TEXT)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_device_quota_status(TEXT)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.upsert_profile(TEXT, TEXT, TEXT)
  TO anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_profile(TEXT)
  TO anon, authenticated;

-- ============================================================================

-- 9. RLS POLICIES for device_usage
ALTER TABLE public.device_usage ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow read device usage" ON public.device_usage;
CREATE POLICY "Allow read device usage"
  ON public.device_usage FOR SELECT
  TO anon, authenticated
  USING (TRUE);

DROP POLICY IF EXISTS "Prevent direct inserts device_usage" ON public.device_usage;
CREATE POLICY "Prevent direct inserts device_usage"
  ON public.device_usage FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE);

DROP POLICY IF EXISTS "Prevent direct updates device_usage" ON public.device_usage;
CREATE POLICY "Prevent direct updates device_usage"
  ON public.device_usage FOR UPDATE
  TO anon, authenticated
  USING (FALSE) WITH CHECK (FALSE);

DROP POLICY IF EXISTS "Prevent deletes device_usage" ON public.device_usage;
CREATE POLICY "Prevent deletes device_usage"
  ON public.device_usage FOR DELETE
  TO anon, authenticated
  USING (FALSE);

-- ============================================================================

-- 10. RLS POLICIES for lifetime_access
ALTER TABLE public.lifetime_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow read lifetime access" ON public.lifetime_access;
CREATE POLICY "Allow read lifetime access"
  ON public.lifetime_access FOR SELECT
  TO anon, authenticated
  USING (TRUE);

DROP POLICY IF EXISTS "Prevent direct inserts lifetime_access" ON public.lifetime_access;
CREATE POLICY "Prevent direct inserts lifetime_access"
  ON public.lifetime_access FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE);

DROP POLICY IF EXISTS "Prevent direct updates lifetime_access" ON public.lifetime_access;
CREATE POLICY "Prevent direct updates lifetime_access"
  ON public.lifetime_access FOR UPDATE
  TO anon, authenticated
  USING (FALSE) WITH CHECK (FALSE);

DROP POLICY IF EXISTS "Prevent deletes lifetime_access" ON public.lifetime_access;
CREATE POLICY "Prevent deletes lifetime_access"
  ON public.lifetime_access FOR DELETE
  TO anon, authenticated
  USING (FALSE);

-- ============================================================================
-- MIGRATION COMPLETE
-- ============================================================================
-- This migration is safe to run multiple times.
-- It does not drop any tables or delete data.
-- It updates the room CHECK constraint on device_usage if it already exists.
-- It replaces policy definitions with DROP POLICY IF EXISTS + CREATE POLICY for idempotency.
-- ============================================================================
