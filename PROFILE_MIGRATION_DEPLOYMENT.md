# Profile Migration - Complete Deployment Guide

## Status
✅ **READY TO DEPLOY**

All code changes completed. The migration introduces:
1. **public.profiles table** - Persistent profile storage per device
2. **RPC functions** - upsert_profile() and get_profile()
3. **Frontend integration** - Profile loading/saving via RPC

---

## Step 1: Deploy SQL Migration

### What To Do
1. Open Supabase Console → SQL Editor
2. Create a new query
3. Copy entire contents of: **supabase-migrations-FIXED.sql**
4. Paste into SQL editor
5. Click "Run"

### Expected Results
- ✅ No errors in output
- ✅ All commands execute successfully (green checkmarks)
- ✅ Execution time: ~2-5 seconds

### Verify Deployment
After running, verify in Supabase Table Browser:

1. **profiles table exists** ✅
   - Columns: id (UUID), device_id (TEXT UNIQUE), username (TEXT), avatar (TEXT), created_at, updated_at
   - Indexes: idx_profiles_device_id
   - RLS: Enabled

2. **Database Functions exist** ✅
   - get_profile(TEXT) → jsonb
   - upsert_profile(TEXT, TEXT, TEXT) → jsonb

---

## Step 2: Test Profile Creation in Frontend

### Test 1: Create Profile
1. Open browser to Infinity Chat
2. Click "PROFILE" tab at bottom
3. Enter username: "TestUser123"
4. Select emoji: 🔥
5. Click "Simpan Profil"
6. Expected: Toast "Profil disimpan ✓"
7. Check browser console:
   - Should see: `Profile saved in Supabase: { success: true, ... }`

### Test 2: Verify Profile in Supabase
1. Open Supabase → Table Browser → profiles
2. Look for row with:
   - device_id: matches browser localStorage (mwc_device_id_v1)
   - username: "TestUser123"
   - avatar: "🔥"
3. ✅ **SUCCESS** if row exists

---

## Step 3: Test Profile Persistence

### Test 3: Refresh Page
1. Profile screen still shows: "TestUser123" with "🔥" avatar
2. Check localStorage: `localStorage.getItem('mwc_profile')`
   - Should show: `{"username":"TestUser123","avatar":"🔥"}`

### Test 4: Change Profile and Refresh
1. Click PROFILE tab
2. Change username to "UpdatedName"
3. Select different emoji: 😎
4. Click "Simpan Profil"
5. Refresh page (F5)
6. Expected: Profile still shows "UpdatedName" and "😎"
7. Verify in Supabase console:
   ```sql
   SELECT * FROM public.profiles 
   WHERE device_id = 'YOUR_DEVICE_ID';
   ```
   Should show updated username and avatar

---

## Step 4: Test Message Sending with Profile

### Test 5: Send Message Uses Profile
1. Go to CHAT tab → Malaysia room
2. Type message: "Testing profile in messages"
3. Click send
4. Your message appears with:
   - Username: "UpdatedName" (from profile)
   - Avatar: "😎" (from profile)
5. Verify in Supabase:
   ```sql
   SELECT username, avatar, content FROM public.messages
   WHERE room = 'malaysia'
   ORDER BY created_at DESC
   LIMIT 1;
   ```
   Should show your username and avatar from profile

---

## Step 5: Test Two Different Devices

### Test 6: Private Window (Different Device)
1. Open new Private/Incognito window
2. Go to same chat app URL
3. Should show anonymous profile initially
4. Go to PROFILE tab
5. Set username: "SecondDevice"
6. Select emoji: 👑
7. Click "Simpan Profil"
8. Send message: "From second device"
9. Expected: Message shows "SecondDevice" with "👑" avatar
10. Verify in Supabase: Two different device_ids, two profiles

### Test 7: Return to Original Window
1. Go back to first window/browser
2. Profile still shows: "UpdatedName" and "😎"
3. Send new message
4. Message has correct username/avatar

---

## Step 6: Test Quota Still Works

### Test 8: Quota Enforcement
1. Go to CHAT → Malaysia room
2. Profile shows correctly
3. Send messages until quota hits 30
4. Expected: "Upgrade" button appears, no more messages allowed
5. Quota should be stored per device_id, not tied to profile
6. Verify quota data independent of profile:
   ```sql
   SELECT * FROM public.device_usage WHERE device_id = 'YOUR_DEVICE_ID';
   ```

---

## Step 7: Test Existing Features Unaffected

### Test 9: Message Actions
- ✅ Reply to messages
- ✅ Copy message text
- ✅ Mute users
- ✅ Report users
- ✅ All should work as before

### Test 10: Room Switching
- ✅ Profile persists when switching rooms
- ✅ Messages in different rooms show correct profile
- ✅ Quota per room still enforced

---

## Troubleshooting

### Problem: Profile not saving
**Solution:**
1. Check browser console for errors
2. Verify Supabase connection is active (status bar shows "Realtime connected")
3. Ensure migration ran successfully
4. Check that get_profile and upsert_profile RPC functions exist

### Problem: "Failed to save profile to server"
**Solution:**
1. Open browser console
2. Run: `localStorage.getItem('mwc_device_id_v1')`
3. Check Supabase logs for RPC errors
4. Verify RLS policies are correctly set on profiles table

### Problem: Profile not loading on refresh
**Solution:**
1. Check localStorage has device_id
2. Verify profiles table has entry for that device_id
3. Check get_profile RPC function executes without errors
4. Check browser console for exceptions

### Problem: RPC function not found (PGRST202)
**Solution:**
1. Verify migration was fully deployed (check all statements executed)
2. Verify function signatures match exactly
3. Try running migration again (it's idempotent)

---

## Files Modified

### 1. supabase-migrations-FIXED.sql
**Changes:**
- Section 0.5: Added public.profiles table creation
- Section 0.5: Added RLS policies for profiles
- Section 7.5: Added upsert_profile() RPC function
- Section 7.6: Added get_profile() RPC function
- Section 8: Added GRANT EXECUTE for new RPC functions

**Lines Added:** ~150

### 2. index.html
**Changes:**
- Line ~1206: Updated loadProfileFromSupabase() to use get_profile RPC
- Line ~1257: Updated saveProfileToSupabase() to use upsert_profile RPC
- Line ~1879: Made initializeApp() async
- Added try/catch around profile sync

**Lines Changed:** ~40

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│ Frontend (index.html)                               │
│ ┌─────────────────────────────────────────────────┐ │
│ │ Profile Screen UI                               │ │
│ │ - Username input                                │ │
│ │ - Emoji selector                                │ │
│ │ - "Simpan Profil" button → saveProfile()        │ │
│ └─────────────────────────────────────────────────┘ │
│                    │                                 │
│                    ↓ (async/await)                   │
│ ┌─────────────────────────────────────────────────┐ │
│ │ saveProfileToSupabase()                         │ │
│ │ → RPC: upsert_profile(device_id, ...)          │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
                    │
                    ↓ HTTP/JSON
┌─────────────────────────────────────────────────────┐
│ Supabase Backend                                    │
│ ┌─────────────────────────────────────────────────┐ │
│ │ upsert_profile(device_id, username, avatar)    │ │
│ │ - Validates inputs                              │ │
│ │ - INSERT ... ON CONFLICT DO UPDATE              │ │
│ └─────────────────────────────────────────────────┘ │
│                    │                                 │
│                    ↓                                 │
│ ┌─────────────────────────────────────────────────┐ │
│ │ public.profiles table                           │ │
│ │ - device_id (UNIQUE index)                      │ │
│ │ - username                                      │ │
│ │ - avatar                                        │ │
│ │ - created_at, updated_at                        │ │
│ │ - RLS: Read all, write via RPC only             │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘

Messages Flow:
┌─────────────────────────────────────────────────────┐
│ Frontend: sendMessage()                             │
│ - Gets current profile (username, avatar)           │
│ - Calls RPC: check_and_send_message(...,            │
│              p_username: profile.username,          │
│              p_avatar: profile.avatar)              │
└─────────────────────────────────────────────────────┘
                    │
                    ↓
┌─────────────────────────────────────────────────────┐
│ Supabase RPC: check_and_send_message()              │
│ - Checks quota (device_usage table)                 │
│ - If OK: INSERT into messages table                 │
│ - Returns success + remaining_quota                 │
└─────────────────────────────────────────────────────┘
                    │
                    ↓
┌─────────────────────────────────────────────────────┐
│ public.messages table                               │
│ - Stores: username, avatar (from profile)           │
│ - Stores: content, room, created_at                 │
│ - RLS: Read all, insert via RPC only                │
└─────────────────────────────────────────────────────┘
```

---

## What Remains Unchanged

✅ **messages.username** and **messages.avatar** columns still exist
✅ **check_and_send_message RPC** function signature unchanged
✅ **Quota system** (30 per room, lifetime access) unchanged
✅ **Chat UI** unchanged (still shows messages from messages table)
✅ **Room switching** logic unchanged
✅ **Lifetime access** system unchanged
✅ **Mute/report/reply functionality** unchanged

---

## Next Steps After Deployment

1. **Deploy SQL migration** to Supabase
2. **Test all 10 test cases** above
3. **Monitor browser console** for any errors
4. **Check Supabase logs** if issues occur
5. **Verify profiles table** has data from your devices
6. **Share feedback** if any issues found

---

## Support

If issues occur:
1. Check browser console (F12)
2. Check Supabase SQL logs
3. Verify migration ran to completion
4. Verify device_id exists in localStorage
5. Run test SQL queries in Supabase SQL editor
