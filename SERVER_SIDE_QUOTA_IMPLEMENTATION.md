# Server-Side Quota Enforcement Implementation Guide

## Overview
This guide explains the server-side quota enforcement system for Infinity Chat. Quotas are managed entirely on the server using Supabase, not relying on client-side localStorage for enforcement.

## Architecture

### Per-Room Limits
- **Malaysia Chat**: 30 messages per device (free)
- **English Chat**: 30 messages per device (free)
- **Chinese Chat**: 30 messages per device (free)
- **Lifetime Access**: Unlimited messages on all rooms

### Key Principle
**Device ID is the only source of identity** - not username, not IP address. Each device gets a unique localStorage-persisted device ID.

---

## Database Schema

### 1. Create device_usage Table
Tracks message count per room per device.

```sql
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

CREATE INDEX IF NOT EXISTS idx_device_usage_device_room 
  ON public.device_usage(device_id, room);
```

### 2. Create lifetime_access Table
Tracks which devices have lifetime access.

```sql
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

CREATE INDEX IF NOT EXISTS idx_lifetime_access_device_id 
  ON public.lifetime_access(device_id) 
  WHERE is_active = TRUE;
```

---

## RPC Functions

### 1. check_and_send_message()
**Purpose**: Atomically enforce quota and send message

**Input Parameters**:
```javascript
{
  p_device_id: "device_abc123",      // Device ID from localStorage
  p_room: "malaysia",                // Room name
  p_username: "John Doe",            // Username
  p_avatar: "😎",                    // Avatar emoji
  p_content: "Hello world",          // Message content
  p_reply_to: null                   // Optional reply-to text
}
```

**Output**:
```javascript
{
  success: boolean,           // true = message sent, false = rejected
  message_id: "uuid-string",  // Message ID if success
  error: "LIMIT_REACHED",     // Error code if failed
  message: "...",             // Error message
  remaining_quota: 15,        // Remaining quota after sending (or 0 if limit reached)
  is_lifetime: boolean        // Whether device has lifetime access
}
```

**Logic**:
1. Check if device has lifetime access
2. If lifetime: Skip quota check, insert message, return success
3. If not lifetime:
   - Get current count for room
   - If count >= 30: Return error
   - Atomically increment count
   - Insert message
   - Return success with remaining quota

### 2. activate_lifetime_access()
**Purpose**: Grant lifetime access to a device (called after Razorpay payment verification)

**Input Parameters**:
```javascript
{
  p_device_id: "device_abc123",
  p_payment_id: "razorpay_payment_123",
  p_payment_method: "razorpay"
}
```

**Output**:
```javascript
{
  success: true,
  message: "Lifetime access activated for device: device_abc123"
}
```

### 3. get_device_quota_status()
**Purpose**: Get current quota status for display (informational only)

**Input Parameters**:
```javascript
{
  p_device_id: "device_abc123"
}
```

**Output** (if lifetime):
```javascript
{
  is_lifetime: true,
  malaysia: { count: -1, limit: -1 },
  english: { count: -1, limit: -1 },
  chinese: { count: -1, limit: -1 }
}
```

**Output** (if regular user):
```javascript
{
  is_lifetime: false,
  malaysia: { count: 15, limit: 30 },
  english: { count: 22, limit: 30 },
  chinese: { count: 8, limit: 30 }
}
```

---

## Frontend Implementation

### Device ID Handling
```javascript
function getDeviceId() {
  let id = localStorage.getItem('mwc_device_id_v1');
  if (!id) {
    id = 'device_' + crypto.randomUUID();
    localStorage.setItem('mwc_device_id_v1', id);
  }
  return id;
}
```

### Sending Message
```javascript
async function sendMessage() {
  // ... input validation ...
  
  const deviceId = getDeviceId();
  const { data, error } = await supabase.rpc('check_and_send_message', {
    p_device_id: deviceId,
    p_room: currentRoom,
    p_username: profile.username,
    p_avatar: profile.avatar,
    p_content: content,
    p_reply_to: replyToText
  });
  
  if (!data.success) {
    if (data.error === 'LIMIT_REACHED') {
      showUpgradeModal(currentRoom);
    }
    return;
  }
  
  // Message sent successfully
  addMessageLocal({...});
}
```

### Razorpay Payment Verification
```javascript
async function handlePaymentSuccess(paymentId, deviceId) {
  // Verify payment on server (backend endpoint)
  const verified = await verifyRazorpayPayment(paymentId);
  
  if (verified) {
    // Grant lifetime access via RPC
    await supabase.rpc('activate_lifetime_access', {
      p_device_id: deviceId,
      p_payment_id: paymentId,
      p_payment_method: 'razorpay'
    });
    
    // Update UI
    loadDeviceQuotaStatus();
  }
}
```

---

## Security Considerations

### What is NOT Trusted
- ❌ `localStorage` quota values (read-only for device ID)
- ❌ `frontend` JavaScript quota enforcement
- ❌ `hidden input` fields
- ❌ `query parameters`
- ❌ `cookies`

### What IS Trusted
- ✅ `Supabase database` (authoritative source)
- ✅ `RPC functions` with atomic operations
- ✅ `Device ID` (persistent, unique per browser)
- ✅ `Server-side payment verification` (before lifetime access)

### Race Condition Prevention
Using SQL's `FOR UPDATE` lock and atomic `UPDATE ... RETURNING`:
```sql
UPDATE public.device_usage
SET message_count = message_count + 1,
    updated_at = CURRENT_TIMESTAMP
WHERE device_id = ? AND room = ?
FOR UPDATE;  -- Row-level lock prevents concurrent increments
```

---

## Migration Steps

### Step 1: Run SQL Migration
1. Go to Supabase Console → SQL Editor
2. Copy the entire content from `supabase-migrations.sql`
3. Click "Run"
4. Verify all tables and functions created

### Step 2: Test RPC Functions
```bash
# Test check_and_send_message
curl -X POST https://your-project.supabase.co/rest/v1/rpc/check_and_send_message \
  -H "apikey: your_anon_key" \
  -H "Content-Type: application/json" \
  -d '{
    "p_device_id": "device_test_123",
    "p_room": "malaysia",
    "p_username": "TestUser",
    "p_avatar": "😎",
    "p_content": "Hello test",
    "p_reply_to": null
  }'
```

### Step 3: Verify Frontend
1. Start HTTP server: `npx http-server -p 3000`
2. Open browser: `http://localhost:3000`
3. Send messages and verify quota is enforced server-side
4. Check `device_usage` table in Supabase to verify counts

---

## Testing Checklist

### Unit Tests (Database Level)
- [ ] device_usage table created with proper constraints
- [ ] lifetime_access table created
- [ ] Indexes created for performance
- [ ] RPC functions execute without errors
- [ ] Atomic increment works (no race conditions)

### Integration Tests (API Level)
- [ ] Message 1-29: All succeed
- [ ] Message 30: Succeeds (last allowed)
- [ ] Message 31: Fails with LIMIT_REACHED
- [ ] Different rooms have separate limits
- [ ] Lifetime access bypasses all limits
- [ ] Razorpay payment verification works

### E2E Tests (Frontend Level)
- [ ] Device ID persists across page reloads
- [ ] Quota display shows correct count
- [ ] Message send button disabled at limit
- [ ] Upgrade modal shows for blocked room
- [ ] Cannot bypass quota by modifying localStorage
- [ ] Cannot send via direct API call (quota enforced)
- [ ] Simultaneous requests don't bypass limit

---

## Troubleshooting

### "Function check_and_send_message does not exist"
- Solution: Re-run SQL migration in Supabase SQL Editor

### "RPC returned success but no message_id"
- Solution: Check that messages table has INSERT permission

### "Quota count never increments"
- Solution: Verify device_usage table has correct device_id value

### "Two requests sent within milliseconds both succeeded"
- Solution: Verify `FOR UPDATE` lock is present in RPC function

---

## Next Steps

1. **Run SQL migration** in Supabase
2. **Test RPC functions** with curl or Postman
3. **Start HTTP server** and test frontend
4. **Verify quota enforcement** works
5. **Deploy to production** with confidence

---

## Files Included

- `index.html` - Updated frontend with RPC calls
- `supabase-migrations.sql` - Complete SQL schema and functions
- `SERVER_SIDE_QUOTA_IMPLEMENTATION.md` - This documentation

---

## Support

For issues or questions:
1. Check Supabase logs for RPC errors
2. Verify device_usage table has correct data
3. Test RPC functions in Supabase SQL Editor
4. Check browser console for frontend errors
