-- Enable all 195 country rooms and realtime message delivery.
-- Run this once on an existing Supabase project.

ALTER TABLE public.device_usage
  DROP CONSTRAINT IF EXISTS device_usage_room_check;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
