# BLOCKER #1: DEPLOYMENT CHECKLIST

**Status:** Ready for deployment  
**File to deploy:** `supabase-migrations-FIXED.sql`  
**Estimated time:** 10 minutes total

---

## PRE-DEPLOYMENT (Before You Start)

- [ ] Read BLOCKER_1_SUMMARY.md (understand what's being fixed)
- [ ] Read BLOCKER_1_DEPLOYMENT.md (step-by-step guide)
- [ ] Have Supabase project open: https://rptclztrmprcxjbolkrt.supabase.co
- [ ] Have VS Code open with `supabase-migrations-FIXED.sql` file

---

## DEPLOYMENT PHASE 1: Execute SQL (5 minutes)

### Step 1.1: Open Supabase SQL Editor
- [ ] Go to: https://supabase.com/dashboard
- [ ] Click on project: `rptclztrmprcxjbolkrt`
- [ ] Left sidebar → Click "SQL Editor"
- [ ] Top right → Click "New Query"

### Step 1.2: Copy Migration File
- [ ] Open file: `supabase-migrations-FIXED.sql` in VS Code
- [ ] Select All: Ctrl+A
- [ ] Copy: Ctrl+C

### Step 1.3: Paste into Supabase
- [ ] Click in SQL Editor text area
- [ ] Paste: Ctrl+V
- [ ] Verify you see ~450 lines of SQL
- [ ] **DO NOT modify anything**

### Step 1.4: Execute
- [ ] Click "Run" button (or Ctrl+Enter)
- [ ] Wait for execution (< 5 seconds)
- [ ] Check "Output" panel

### Step 1.5: Verify Execution Success
- [ ] Look at Output panel
- [ ] Verify: No "ERROR" or "SQLSTATE" messages
- [ ] Verify: All queries executed (should show green checkmarks)
- [ ] **STOP HERE if there are errors** (see troubleshooting)

---

## DEPLOYMENT PHASE 2: Verify Tables & Functions (2 minutes)

### Step 2.1: Check Tables Exist
- [ ] Left sidebar → Click "Table Editor"
- [ ] Look for `messages` table (should be new)
- [ ] Click on it → Verify columns:
  - [ ] id (UUID)
  - [ ] room (TEXT)
  - [ ] username (TEXT)
  - [ ] avatar (TEXT)
  - [ ] content (TEXT)
  - [ ] reply_to (TEXT, nullable)
  - [ ] created_at (TIMESTAMP)
  - [ ] updated_at (TIMESTAMP)
- [ ] Look for `device_usage` table (should be updated)
- [ ] Click on it → Check Constraints tab:
  - [ ] Constraint should include all 33 room names (not just 3)
- [ ] Look for `lifetime_access` table (should exist)

### Step 2.2: Check Functions Exist
- [ ] Left sidebar → Click "Database Functions"
- [ ] Look for: `check_and_send_message` (should exist)
- [ ] Look for: `activate_lifetime_access` (should exist)
- [ ] Look for: `get_device_quota_status` (should exist)
- [ ] Click each one → Verify parameters are correct:

**check_and_send_message should have:**
```
p_device_id TEXT
p_room TEXT
p_username TEXT
p_avatar TEXT
p_content TEXT
p_reply_to TEXT (default)
```

**activate_lifetime_access should have:**
```
p_device_id TEXT
p_payment_id TEXT (default)
p_payment_method TEXT (default)
```

**get_device_quota_status should have:**
```
p_device_id TEXT
```

---

## DEPLOYMENT PHASE 3: Browser Testing (3 minutes)

### Step 3.1: Refresh Browser
- [ ] Browser with app open: http://localhost:3000
- [ ] Hard refresh: Ctrl+Shift+R (clears cache)
- [ ] App should load normally

### Step 3.2: Open Developer Console
- [ ] Press: F12
- [ ] Click: "Console" tab
- [ ] You should see some logs from app startup

### Step 3.3: Test 1 - Function Exists (No PGRST202)
- [ ] Copy this command:
```javascript
await window.supabaseClient.rpc('get_device_quota_status', {
  p_device_id: localStorage.getItem('mwc_device_id_v1')
}).then(r => console.log('Result:', r))
```
- [ ] Paste into console and press Enter
- [ ] Check result:
  - [ ] **✅ PASS:** Shows `data: { is_lifetime: false, malaysia: {...}, ... }`
  - [ ] **❌ FAIL:** Shows `error: { code: PGRST202 }`

### Step 3.4: Test 2 - All 33 Rooms Returned
- [ ] Copy this command:
```javascript
await window.supabaseClient.rpc('get_device_quota_status', {
  p_device_id: localStorage.getItem('mwc_device_id_v1')
}).then(r => {
  const roomCount = Object.keys(r.data).filter(k => k !== 'is_lifetime').length;
  console.log(`Room count: ${roomCount}`);
  console.log('Rooms:', Object.keys(r.data).filter(k => k !== 'is_lifetime'));
})
```
- [ ] Paste into console and press Enter
- [ ] Check result:
  - [ ] **✅ PASS:** Shows `Room count: 33` (or more)
  - [ ] **❌ FAIL:** Shows `Room count: 3` (old behavior)
  - [ ] **❌ FAIL:** Shows `error: PGRST202`

### Step 3.5: Test 3 - Send Message Works
- [ ] In app, type message: "Test deployment"
- [ ] Press Send
- [ ] Check result:
  - [ ] **✅ PASS:** Message appears in chat
  - [ ] **✅ PASS:** No "Error sending message" toast
  - [ ] **❌ FAIL:** See error toast (check console for PGRST202)

### Step 3.6: Test 4 - Send to Japan Room (Non-Malaysia)
- [ ] Click "Japan" channel button
- [ ] Type message: "Test Japan room"
- [ ] Press Send
- [ ] Check result:
  - [ ] **✅ PASS:** Message appears
  - [ ] **✅ PASS:** No constraint error
  - [ ] **❌ FAIL:** Error toast with "constraint" in message

---

## FINAL VERIFICATION (1 minute)

### All Tests Passed?
- [ ] Test 1: ✅ No PGRST202
- [ ] Test 2: ✅ 33 rooms returned
- [ ] Test 3: ✅ Message sent successfully
- [ ] Test 4: ✅ Japan room accepts message

### Tables & Functions Exist?
- [ ] ✅ messages table exists
- [ ] ✅ device_usage has all 33 rooms in constraint
- [ ] ✅ lifetime_access table exists
- [ ] ✅ check_and_send_message function exists
- [ ] ✅ activate_lifetime_access function exists
- [ ] ✅ get_device_quota_status function exists

---

## BLOCKER #1 STATUS

### If All Tests ✅ Pass:
```
✅ BLOCKER #1 IS FIXED

You can now proceed to:
- BLOCKER #2: Fix database schema to support all 33 rooms
- BLOCKER #3: Implement Razorpay payment integration
- BLOCKER #4: Remove unsafe lifetime access grant
```

### If Any Test ❌ Fails:
```
❌ BLOCKER #1 NOT YET FIXED

Troubleshooting:
1. Check SQL execution had no errors (Step 1.5)
2. Check tables exist in Table Editor (Step 2.1)
3. Check functions exist in Database Functions (Step 2.2)
4. Hard refresh browser (Ctrl+Shift+R)
5. Check browser console for specific error
6. See BLOCKER_1_DEPLOYMENT.md → Troubleshooting section
7. If still stuck: Re-run supabase-migrations-FIXED.sql
```

---

## QUICK REFERENCE: Key Files

| File | Purpose | Read It If... |
|------|---------|---------------|
| `supabase-migrations-FIXED.sql` | The deployment file | You need to deploy to Supabase |
| `BLOCKER_1_SUMMARY.md` | What was added/fixed | You want to understand the changes |
| `BLOCKER_1_DEPLOYMENT.md` | Step-by-step guide | You need detailed instructions |
| `BLOCKER_1_VISUAL.md` | Visual deployment guide | You prefer diagrams/examples |
| `BLOCKER_1_CURRENT_VS_REQUIRED.md` | Before/after state | You want full technical details |
| `BLOCKER_1_COMPARISON.md` | Code comparison | You want to see exact code changes |

---

## TIMELINE

```
[You are here] ← BLOCKER #1 Ready for Deployment
        ↓
    [Execute SQL] ← 5 minutes
        ↓
 [Verify in Browser] ← 5 minutes
        ↓
✅ BLOCKER #1 FIXED ← 10 minutes total
        ↓
[Proceed to BLOCKER #2/3/4]
```

---

## IMPORTANT NOTES

1. **Use the FIXED file:** Use `supabase-migrations-FIXED.sql` (NOT old `supabase-migrations.sql`)
2. **No UI changes:** Only backend deployment, app UI unchanged
3. **Idempotent:** Safe to run multiple times (uses IF NOT EXISTS)
4. **No data loss:** No DROP statements, only adding/updating
5. **Fast execution:** Should complete in < 5 seconds

---

## POST-DEPLOYMENT

After BLOCKER #1 is fixed:

- [ ] Notify that RPC functions are working
- [ ] Verify all 33 countries can send messages
- [ ] Move to BLOCKER #2 (if needed)
- [ ] Move to BLOCKER #3: Razorpay integration
- [ ] Move to BLOCKER #4: Remove unsafe access grant

---

**Ready to start? Begin with Step 1.1 above.**

