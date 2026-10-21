-- Deprecated: this migration previously enabled unrestricted chat sending.
-- Remove its legacy overload so it cannot bypass paid-global-chat-access-migration.sql.
-- Apply paid-global-chat-access-migration.sql after the latest chat-message migration.

DROP FUNCTION IF EXISTS public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID);

NOTIFY pgrst, 'reload schema';
