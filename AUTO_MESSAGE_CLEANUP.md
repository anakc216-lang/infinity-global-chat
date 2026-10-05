# Automatic message cleanup

Run [auto-clear-messages-at-200k-migration.sql](./auto-clear-messages-at-200k-migration.sql) once in the Supabase SQL Editor.

The migration counts existing rows, then keeps the count in a private database table. Every new message increments the counter transactionally, and normal message deletions (including moderation deletions) decrement it. When the count reaches 200,000, the database deletes every row from `public.messages` and resets the counter. Other tables are not changed. Because the cleanup runs in the same transaction as the threshold message, that message is deleted too.

This is permanent deletion from the live table. Keep a Supabase backup/PITR plan if messages may need recovery. Existing messages already loaded in an open browser can remain visible in that browser until it reloads or fetches the room again.
