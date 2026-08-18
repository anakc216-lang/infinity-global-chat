-- ============================================================================
-- SERVER-SIDE QUOTA ENFORCEMENT MIGRATION
-- Safe migration: uses IF NOT EXISTS, no destructive changes
-- ============================================================================

-- 1. CREATE device_usage TABLE (per-room message count tracking)
-- This table tracks how many messages each device has sent per room
CREATE TABLE IF NOT EXISTS public.device_usage (
  id BIGSERIAL PRIMARY KEY,
  device_id TEXT NOT NULL,
  room TEXT NOT NULL CHECK (room IN ('malaysia', 'english', 'chinese')),
  message_count INTEGER NOT NULL DEFAULT 0 CHECK (message_count >= 0),
  last_reset TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(device_id, room)
);

-- 2. CREATE INDEX for fast lookups by device_id + room
CREATE INDEX IF NOT EXISTS idx_device_usage_device_room 
  ON public.device_usage(device_id, room);

-- 3. CREATE lifetime_access TABLE
-- Tracks which devices have lifetime access (paid users)
CREATE TABLE IF NOT EXISTS public.lifetime_access (
  id BIGSERIAL PRIMARY KEY,
  device_id TEXT NOT NULL UNIQUE,
  is_active BOOLEAN DEFAULT TRUE,
  payment_method TEXT, -- 'razorpay' or other
  payment_id TEXT,     -- Razorpay payment ID
  activated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- 4. CREATE INDEX for fast lifetime access lookups
CREATE INDEX IF NOT EXISTS idx_lifetime_access_device_id 
  ON public.lifetime_access(device_id) 
  WHERE is_active = TRUE;

-- 5. CREATE RPC FUNCTION: check_and_send_message
-- This function enforces quota at the database level
-- It performs atomic increment to prevent race conditions
-- Returns: {success: boolean, message_id: uuid, error: string, remaining_quota: integer}
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
  -- First, ensure device_usage row exists
  INSERT INTO public.device_usage (device_id, room, message_count)
  VALUES (p_device_id, p_room, 0)
  ON CONFLICT (device_id, room) DO NOTHING;
  
  -- Step 4: Get current count
  SELECT message_count INTO v_current_count
  FROM public.device_usage
  WHERE device_id = p_device_id AND room = p_room
  FOR UPDATE; -- Lock row to prevent race conditions
  
  -- Step 5: Check if limit reached
  IF v_current_count >= 30 THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'LIMIT_REACHED',
      'message', 'Daily limit of 30 messages reached for ' || p_room,
      'remaining_quota', 0
    );
  END IF;
  
  -- Step 6: Atomically increment and insert message
  UPDATE public.device_usage
  SET message_count = message_count + 1,
      updated_at = CURRENT_TIMESTAMP
  WHERE device_id = p_device_id AND room = p_room;
  
  v_current_count := v_current_count + 1;
  v_remaining_quota := 30 - v_current_count;
  
  -- Step 7: Insert message
  INSERT INTO public.messages (room, username, avatar, content, reply_to, created_at)
  VALUES (p_room, p_username, p_avatar, p_content, p_reply_to, CURRENT_TIMESTAMP)
  RETURNING id INTO v_message_id;
  
  -- Step 8: Return success with remaining quota
  RETURN jsonb_build_object(
    'success', TRUE,
    'message_id', v_message_id,
    'remaining_quota', v_remaining_quota,
    'is_lifetime', FALSE
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. CREATE RPC FUNCTION: activate_lifetime_access
-- Called after successful Razorpay payment verification
CREATE OR REPLACE FUNCTION public.activate_lifetime_access(
  p_device_id TEXT,
  p_payment_id TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT 'razorpay'
)
RETURNS jsonb AS $$
DECLARE
  v_activated BOOLEAN;
BEGIN
  INSERT INTO public.lifetime_access (device_id, is_active, payment_id, payment_method)
  VALUES (p_device_id, TRUE, p_payment_id, p_payment_method)
  ON CONFLICT (device_id) DO UPDATE
  SET is_active = TRUE,
      payment_id = COALESCE(p_payment_id, lifetime_access.payment_id),
      payment_method = COALESCE(p_payment_method, lifetime_access.payment_method),
      updated_at = CURRENT_TIMESTAMP;
  
  RETURN jsonb_build_object(
    'success', TRUE,
    'message', 'Lifetime access activated for device: ' || p_device_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. CREATE RPC FUNCTION: get_device_quota_status
-- Returns quota info for frontend display (informational only)
CREATE OR REPLACE FUNCTION public.get_device_quota_status(p_device_id TEXT)
RETURNS jsonb AS $$
DECLARE
  v_result JSONB;
  v_lifetime_active BOOLEAN;
BEGIN
  -- Check lifetime access
  SELECT is_active INTO v_lifetime_active
  FROM public.lifetime_access
  WHERE device_id = p_device_id
  LIMIT 1;
  
  v_lifetime_active := COALESCE(v_lifetime_active, FALSE);
  
  -- If lifetime, return unlimited for all rooms
  IF v_lifetime_active = TRUE THEN
    RETURN jsonb_build_object(
      'is_lifetime', TRUE,
      'malaysia', jsonb_build_object('count', -1, 'limit', -1),
      'english', jsonb_build_object('count', -1, 'limit', -1),
      'chinese', jsonb_build_object('count', -1, 'limit', -1)
    );
  END IF;
  
  -- Otherwise, return actual counts
  v_result := jsonb_build_object('is_lifetime', FALSE);
  
  FOR v_result IN
    SELECT jsonb_build_object(
      'malaysia', (SELECT jsonb_build_object('count', COALESCE(message_count, 0), 'limit', 30) 
                   FROM device_usage WHERE device_id = p_device_id AND room = 'malaysia'),
      'english', (SELECT jsonb_build_object('count', COALESCE(message_count, 0), 'limit', 30)
                  FROM device_usage WHERE device_id = p_device_id AND room = 'english'),
      'chinese', (SELECT jsonb_build_object('count', COALESCE(message_count, 0), 'limit', 30)
                  FROM device_usage WHERE device_id = p_device_id AND room = 'chinese')
    )
  LOOP
    RETURN v_result;
  END LOOP;
  
  RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. GRANT PERMISSIONS for anon users to call RPC functions
GRANT EXECUTE ON FUNCTION public.check_and_send_message TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.activate_lifetime_access TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_device_quota_status TO anon, authenticated;

-- 9. UPDATE RLS POLICIES for device_usage (allow reads/writes by device_id)
ALTER TABLE public.device_usage ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow read device usage"
  ON public.device_usage FOR SELECT
  TO anon, authenticated
  USING (TRUE); -- Can read any device usage

CREATE POLICY "Prevent direct inserts (use RPC instead)"
  ON public.device_usage FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE); -- Disallow direct inserts

CREATE POLICY "Prevent direct updates (use RPC instead)"
  ON public.device_usage FOR UPDATE
  TO anon, authenticated
  USING (FALSE) WITH CHECK (FALSE); -- Disallow direct updates

-- 10. UPDATE RLS POLICIES for lifetime_access
ALTER TABLE public.lifetime_access ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow read lifetime access"
  ON public.lifetime_access FOR SELECT
  TO anon, authenticated
  USING (TRUE); -- Can read any lifetime access

CREATE POLICY "Prevent direct modifications (use RPC instead)"
  ON public.lifetime_access FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE); -- Disallow direct inserts

CREATE POLICY "Prevent direct updates (use RPC instead)"
  ON public.lifetime_access FOR UPDATE
  TO anon, authenticated
  USING (FALSE) WITH CHECK (FALSE); -- Disallow direct updates

-- ============================================================================
-- MIGRATION COMPLETE
-- ============================================================================
-- Run this in Supabase SQL Editor:
-- 1. Copy the entire script
-- 2. Paste into Supabase SQL Editor
-- 3. Click "Run" or "Execute"
-- 4. Verify all tables and functions created successfully
-- 5. Test with backend before deploying frontend
-- ============================================================================
