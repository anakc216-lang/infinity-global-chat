# BLOCKER #1 DEPLOYMENT GUIDE
## Supabase Backend - RPC Functions & Schema

**Current Status:** ❌ FAIL - Functions return PGRST202 (not found)  
**Target Status:** ✅ PASS - Functions exist and can be called  
**Estimated Time:** 10 minutes

---

## WHAT WAS WRONG

### Issue 1: Missing `messages` Table
- **Problem:** RPC functions INSERT into `public.messages` table, but it doesn't exist
- **Impact:** All sends fail with foreign key or table not found error
- **Fix:** Created table with proper columns and indexes

### Issue 2: CHECK Constraint Limited to 3 Rooms
- **Problem:** `CHECK (room IN ('malaysia', 'english', 'chinese'))` only allows 3 rooms
- **Impact:** Sending to any of 30 other countries fails: "violates check constraint device_usage_room_check"
- **Fix:** Updated constraint to include all 33 country room IDs

### Issue 3: `get_device_quota_status()` Only Returns 3 Rooms
- **Problem:** Function hardcoded only malaysia, english, chinese
- **Impact:** Frontend cannot get quota status for other 30 countries
- **Fix:** Rewritten to dynamically return status for all 33 rooms

### Issue 4: Missing RLS Policies
- **Problem:** No RLS policies prevent users from directly modifying quota tables
- **Impact:** Users could theoretically bypass quota by directly updating `device_usage` table
- **Fix:** Added RLS policies to force all writes through RPC functions

---

## EXACTLY WHAT TO EXECUTE

### Step 1: Copy the Corrected SQL Migration

The file **`supabase-migrations-FIXED.sql`** contains:

✅ All required tables:
- `public.messages` - Chat messages (NEW)
- `public.device_usage` - Per-room quota tracking (FIXED)
- `public.lifetime_access` - Lifetime access status

✅ All required RPC functions:
- `check_and_send_message()` - Atomic quota enforcement
- `activate_lifetime_access()` - Grant lifetime access
- `get_device_quota_status()` - Get quota status for all 33 rooms (FIXED)

✅ All required RLS policies (NEW)
✅ Support for all 33 country channels (FIXED)

### Step 2: Deploy to Supabase

1. **Open Supabase Console**
   - Go to: https://supabase.com/dashboard
   - Select project: `https://rptclztrmprcxjbolkrt.supabase.co`

2. **Go to SQL Editor**
   - Click: "SQL Editor" in left sidebar
   - Click: "New Query"

3. **Paste the Migration**
   - Open file: `supabase-migrations-FIXED.sql`
   - Copy entire content
   - Paste into Supabase SQL Editor
   - **DO NOT modify anything**

4. **Execute**
   - Click: "Run" button (or Ctrl+Enter)
   - Wait for completion (should be < 5 seconds)
   - Look for: ✅ "Success" message
   - **Do NOT proceed if there are errors**

5. **Verify Execution**
   - Look at "Output" panel
   - Should show: No errors, all queries executed
   - Should NOT show: SQLSTATE, ERROR, or constraint violation

---

## WHAT GETS CREATED

After execution, Supabase will have:

### Tables (3 total)
```
public.messages
  - id (UUID primary key)
  - room (TEXT)
  - username (TEXT)
  - avatar (TEXT)
  - content (TEXT)
  - reply_to (TEXT)
  - created_at (TIMESTAMP)
  - updated_at (TIMESTAMP)

public.device_usage
  - id (BIGSERIAL primary key)
  - device_id (TEXT)
  - room (TEXT) - ✅ NOW SUPPORTS ALL 33 ROOMS
  - message_count (INTEGER)
  - created_at, updated_at (TIMESTAMP)
  - UNIQUE(device_id, room)
  - INDEX: idx_device_usage_device_room

public.lifetime_access
  - id (BIGSERIAL primary key)
  - device_id (TEXT UNIQUE)
  - is_active (BOOLEAN)
  - payment_method (TEXT)
  - payment_id (TEXT)
  - activated_at, created_at, updated_at (TIMESTAMP)
  - INDEX: idx_lifetime_access_device_id
```

### RPC Functions (3 total)
```
public.check_and_send_message(
  p_device_id TEXT,
  p_room TEXT,
  p_username TEXT,
  p_avatar TEXT,
  p_content TEXT,
  p_reply_to TEXT
) RETURNS jsonb

public.activate_lifetime_access(
  p_device_id TEXT,
  p_payment_id TEXT,
  p_payment_method TEXT
) RETURNS jsonb

public.get_device_quota_status(
  p_device_id TEXT
) RETURNS jsonb
```

### RLS Policies
- All tables have RLS enabled
- Users can READ but NOT directly INSERT/UPDATE
- All writes must go through RPC functions
- RPC functions have `SECURITY DEFINER` to bypass RLS

---

## VERIFICATION CHECKLIST

### Quick Verification (1 minute)

After executing SQL, immediately check:

✅ **In Supabase Console:**
- Go to: "Table Editor"
- Look for tables:
  - `messages` (should exist)
  - `device_usage` (should exist)
  - `lifetime_access` (should exist)
- Go to: "Database Functions"
- Look for functions:
  - `check_and_send_message` (should exist)
  - `activate_lifetime_access` (should exist)
  - `get_device_quota_status` (should exist)

### Runtime Verification (5 minutes)

**In browser, test that send works:**

1. Open app: http://localhost:3000
2. Type message: "Test message"
3. Click Send
4. Expected result: ✅ Message appears (NOT "Error sending message")
5. Check browser console: ✅ No PGRST202 error

**In browser, test quota status:**

1. Open browser developer tools: F12 → Console
2. Run command:
   ```javascript
   await window.supabaseClient.rpc('get_device_quota_status', {
     p_device_id: localStorage.getItem('mwc_device_id_v1')
   }).then(r => console.log(JSON.stringify(r.data, null, 2)))
   ```
3. Expected result: ✅ Shows quota for all rooms (or unlimited if lifetime)
4. Expected NOT to show: ❌ PGRST202 or "function not found"

### Advanced Verification (via curl)

If you want to test API directly:

```bash
# Test 1: Get quota status
curl -X POST "https://rptclztrmprcxjbolkrt.supabase.co/rest/v1/rpc/get_device_quota_status" \
  -H "apikey: sb_publishable_dC42vWY0jLb-inau0VdWVQ_E9k5JhRY" \
  -H "Content-Type: application/json" \
  -d '{"p_device_id": "device_test_123"}'

# Expected response: 200 OK with JSON
# {
#   "is_lifetime": false,
#   "malaysia": {"count": 0, "limit": 30},
#   "english": {"count": 0, "limit": 30},
#   ... (all 33 rooms)
# }
```

---

## TROUBLESHOOTING

### Error: "PGRST202: Could not find the function"
**Cause:** SQL migration didn't execute successfully
**Fix:**
1. Go back to SQL Editor
2. Check "Output" panel for error messages
3. Look for: `ERROR` or `SQLSTATE`
4. Copy error message and read carefully
5. Common issues:
   - Copy/paste failed (missing characters)
   - Existing constraints conflict (check Constraints tab in Table Editor)
   - Wrong project selected in Supabase

### Error: "violates check constraint device_usage_room_check"
**Cause:** Old CHECK constraint still exists from before migration
**Fix:**
1. Go to Supabase Console
2. Go to "Table Editor" → "device_usage"
3. Click "Constraints" tab
4. Delete constraint: "device_usage_room_check"
5. Re-run SQL migration
6. (The migration should have replaced it, this shouldn't happen)

### Error: "INSERT violates unique constraint"
**Cause:** device_usage row already exists for that device+room
**Fix:**
- This is EXPECTED behavior on second and subsequent messages
- The RPC handles this with `ON CONFLICT ... DO NOTHING`
- You should NOT see this error in browser (it's handled)

### Function exists but still returns PGRST202
**Cause:** Cache issue in Supabase API
**Fix:**
1. Wait 30 seconds (API cache refresh)
2. Hard refresh browser: Ctrl+Shift+R
3. Clear browser cache: DevTools → Application → Clear All
4. Try again

---

## AFTER SUCCESSFUL DEPLOYMENT

✅ BLOCKER #1 IS FIXED

Next steps (do NOT proceed yet):

1. **BLOCKER #2:** Fix database schema to support all 33 rooms
   - Status: Should already be fixed by supabase-migrations-FIXED.sql
   - Verify: Send message to "japan" room succeeds

2. **BLOCKER #3:** Implement Razorpay payment integration
   - Status: Not yet started
   - Requires: Backend API endpoints + frontend Razorpay Checkout flow

3. **BLOCKER #4:** Remove unsafe lifetime access grant
   - Status: Not yet started
   - Depends on: BLOCKER #3 (Razorpay)

---

## FILES INVOLVED

| File | Status | Purpose |
|------|--------|---------|
| `supabase-migrations-FIXED.sql` | ✅ NEW | Complete SQL migration with all fixes |
| `supabase-migrations.sql` | 🗑️ OLD | Original file (has bugs - do NOT use) |
| `index.html` | ✅ UNCHANGED | No changes needed |
| `SERVER_SIDE_QUOTA_IMPLEMENTATION.md` | ℹ️ DOCS | Reference documentation |

---

**DO NOT PROCEED BEYOND THIS POINT until BLOCKER #1 is verified as FIXED.**
