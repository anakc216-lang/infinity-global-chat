# BLOCKER #1: BEFORE & AFTER COMPARISON

## WHAT CURRENTLY EXISTS (Before)

### Database Schema Issues

#### Issue 1: Missing `messages` Table
```sql
-- ❌ BEFORE: Table doesn't exist
-- RPC function tries to INSERT INTO public.messages
-- Result: Function fails when executed

-- ✅ AFTER:
CREATE TABLE IF NOT EXISTS public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  room TEXT NOT NULL,
  username TEXT NOT NULL,
  avatar TEXT NOT NULL,
  content TEXT NOT NULL,
  reply_to TEXT,
  created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);
```

#### Issue 2: CHECK Constraint Only Allows 3 Rooms
```sql
-- ❌ BEFORE:
CREATE TABLE public.device_usage (
  ...
  room TEXT NOT NULL CHECK (room IN ('malaysia', 'english', 'chinese')),
  ...
);
-- Only allows: malaysia, english, chinese
-- Fails for: japan, united_states, brazil, etc. (30 countries)
-- Error: "violates check constraint device_usage_room_check"

-- ✅ AFTER:
CREATE TABLE public.device_usage (
  ...
  room TEXT NOT NULL CHECK (room IN (
    'malaysia', 'english', 'chinese', 'united_states', 'japan', 'south_korea',
    'singapore', 'indonesia', 'thailand', 'vietnam', 'philippines', 'india',
    'australia', 'new_zealand', 'canada', 'united_kingdom', 'france', 'germany',
    'italy', 'spain', 'netherlands', 'saudi_arabia', 'uae', 'turkey',
    'brazil', 'mexico', 'south_africa', 'egypt', 'nigeria', 'pakistan',
    'bangladesh', 'poland', 'russia'
  )),
  ...
);
-- Now allows all 33 country rooms
```

#### Issue 3: `get_device_quota_status()` Only Returns 3 Rooms
```sql
-- ❌ BEFORE:
CREATE OR REPLACE FUNCTION public.get_device_quota_status(p_device_id TEXT)
RETURNS jsonb AS $$
BEGIN
  -- Hardcoded to return only 3 rooms:
  RETURN jsonb_build_object(
    'is_lifetime', TRUE,
    'malaysia', jsonb_build_object('count', -1, 'limit', -1),
    'english', jsonb_build_object('count', -1, 'limit', -1),
    'chinese', jsonb_build_object('count', -1, 'limit', -1)
    -- No other rooms! Missing 30 countries
  );
END;

-- ✅ AFTER:
CREATE OR REPLACE FUNCTION public.get_device_quota_status(p_device_id TEXT)
RETURNS jsonb AS $$
DECLARE
  v_result JSONB;
BEGIN
  -- Dynamically loops through all 33 rooms
  FOR v_room IN 
    SELECT DISTINCT room 
    FROM (VALUES 
      ('malaysia'), ('english'), ('chinese'), ('united_states'), ('japan'), ...
      -- All 33 rooms listed
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
```

#### Issue 4: Missing RLS Policies
```sql
-- ❌ BEFORE: No RLS policies
-- Users could theoretically:
-- INSERT INTO device_usage (device_id, room, message_count) VALUES ('device_123', 'malaysia', -999)
-- → Bypass quota entirely
-- UPDATE device_usage SET message_count = -999 WHERE device_id = 'device_123'
-- → No quota enforcement

-- ✅ AFTER: Strict RLS policies
ALTER TABLE public.device_usage ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Prevent direct inserts device_usage"
  ON public.device_usage FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE);  -- ← Explicitly DENY

CREATE POLICY "Prevent direct updates device_usage"
  ON public.device_usage FOR UPDATE
  TO anon, authenticated
  USING (FALSE) WITH CHECK (FALSE);  -- ← Explicitly DENY

-- Now only RPC functions (with SECURITY DEFINER) can modify
```

---

## VERIFICATION: WHAT TO EXPECT

### Before Deployment (Current)

**When sending a message:**
```
User: Types "Hello" in Japan channel and clicks Send

Frontend JavaScript:
await supabaseClient.rpc('check_and_send_message', {
  p_device_id: 'device_abc123',
  p_room: 'japan',
  p_username: 'JohnDoe',
  p_avatar: '😎',
  p_content: 'Hello'
})

Supabase Response:
{
  error: {
    code: PGRST202,
    message: "Could not find the function public.check_and_send_message"
  }
}

Browser Toast: "Error sending message"
```

### After Deployment (Expected)

**When sending a message:**
```
User: Types "Hello" in Japan channel and clicks Send

Frontend JavaScript:
await supabaseClient.rpc('check_and_send_message', {
  p_device_id: 'device_abc123',
  p_room: 'japan',
  p_username: 'JohnDoe',
  p_avatar: '😎',
  p_content: 'Hello'
})

Supabase Response:
{
  data: {
    success: true,
    message_id: "550e8400-e29b-41d4-a716-446655440000",
    remaining_quota: 29,
    is_lifetime: false
  },
  error: null
}

Browser Toast: "Message sent ✓"
Message appears in chat: "JohnDoe 😎 • Hello"
```

---

## TEST CASES

### Test 1: Send Message to Non-Malaysia Room
```
Scenario: User in 'japan' room (not 'malaysia')
Before: ❌ FAIL - CHECK constraint error
After: ✅ PASS - Message sends and quota tracked

Database check:
SELECT * FROM device_usage WHERE room='japan' AND device_id='device_123';
Before: (no row) OR error on INSERT
After: { device_id: 'device_123', room: 'japan', message_count: 1 }
```

### Test 2: Get Quota Status for All Rooms
```
Scenario: Frontend requests quota status
Before: ❌ Only returns 3 rooms (missing 30)
After: ✅ Returns all 33 rooms

Call:
const quota = await supabaseClient.rpc('get_device_quota_status', {
  p_device_id: 'device_123'
})

Before response:
{
  is_lifetime: false,
  malaysia: { count: 5, limit: 30 },
  english: { count: 3, limit: 30 },
  chinese: { count: 2, limit: 30 }
  // Missing 30 other countries!
}

After response:
{
  is_lifetime: false,
  malaysia: { count: 5, limit: 30 },
  english: { count: 3, limit: 30 },
  chinese: { count: 2, limit: 30 },
  united_states: { count: 0, limit: 30 },
  japan: { count: 1, limit: 30 },
  south_korea: { count: 0, limit: 30 },
  ...
  // All 33 rooms included!
}
```

### Test 3: Prevent Direct Quota Bypass
```
Scenario: User tries to directly modify quota (without payment)
Before: ❌ Could work (no RLS)
After: ✅ Blocked by RLS

Attacker tries:
await supabaseClient
  .from('device_usage')
  .update({ message_count: -999 })
  .eq('device_id', 'device_123')

Before: ✅ Update succeeds (SECURITY ISSUE!)
After: Error: "new row violates row-level security policy 'Prevent direct updates device_usage'"
```

---

## DEPLOYMENT STEPS

**File to use:** `supabase-migrations-FIXED.sql`

### Step-by-Step

1. Go to: https://supabase.com/dashboard
2. Select project: `rptclztrmprcxjbolkrt`
3. Click: "SQL Editor"
4. Click: "New Query"
5. **Copy entire content** of `supabase-migrations-FIXED.sql`
6. **Paste** into SQL editor
7. Click: "Run"
8. **Wait** for execution (< 5 seconds)
9. Check: ✅ No errors in Output panel
10. Verify: Tables and functions exist (Table Editor, Database Functions)

### Verification Commands

```javascript
// In browser console:

// Test 1: Call check_and_send_message
await window.supabaseClient.rpc('check_and_send_message', {
  p_device_id: 'test_device_001',
  p_room: 'japan',  // Not malaysia/english/chinese
  p_username: 'TestUser',
  p_avatar: '🧪',
  p_content: 'Test message'
}).then(r => console.log(r))

// Should return: { data: { success: true, message_id: "...", remaining_quota: 29 }, error: null }
// NOT: { error: { code: PGRST202 } }

// Test 2: Call get_device_quota_status
await window.supabaseClient.rpc('get_device_quota_status', {
  p_device_id: 'test_device_001'
}).then(r => console.log(Object.keys(r.data).length, "rooms returned"))

// Should return: 33 (all countries)
// NOT: 3 (just malaysia, english, chinese)

// Test 3: Try to bypass via direct update (should fail)
await window.supabaseClient
  .from('device_usage')
  .update({ message_count: 999 })
  .eq('device_id', 'test_device_001')
  .then(r => console.log("UPDATE result:", r))

// Should return: error about RLS policy
// NOT: success (that would be SECURITY ISSUE)
```

---

## SUCCESS CRITERIA

✅ **BLOCKER #1 is FIXED when:**

1. **RPC functions exist and are callable**
   - No PGRST202 errors
   - Functions return proper JSON responses

2. **All 33 rooms supported**
   - Can send to 'japan', 'brazil', 'poland', etc.
   - No CHECK constraint errors

3. **Quota status returns all 33 rooms**
   - `get_device_quota_status()` returns all country rooms
   - Frontend can display quota for all channels

4. **RLS prevents quota bypass**
   - Direct table inserts/updates are blocked
   - Only RPC functions can modify (with proper auth)

5. **No security regressions**
   - Users cannot grant themselves lifetime access by modifying tables
   - Device ID is still the only identifier

---

## ROLLBACK (If Something Goes Wrong)

If migration fails and you need to rollback:

1. Go to Supabase SQL Editor
2. Run this to drop the functions (not tables, keep data):
   ```sql
   DROP FUNCTION IF EXISTS public.check_and_send_message;
   DROP FUNCTION IF EXISTS public.activate_lifetime_access;
   DROP FUNCTION IF EXISTS public.get_device_quota_status;
   ```
3. Then re-run `supabase-migrations-FIXED.sql`

**Do NOT drop tables** (keeps user data safe).

---

## FILES REFERENCE

| File | Contains | Status |
|------|----------|--------|
| `supabase-migrations-FIXED.sql` | Complete corrected migration | ✅ USE THIS |
| `supabase-migrations.sql` | Original buggy migration | 🗑️ DO NOT USE |
| `BLOCKER_1_DEPLOYMENT.md` | Step-by-step deployment guide | ℹ️ REFERENCE |
| `BLOCKER_1_COMPARISON.md` | This document | ℹ️ UNDERSTANDING |

