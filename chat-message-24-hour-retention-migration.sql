-- Permanently remove public chat messages after 24 hours.
-- Run this migration in the Supabase SQL Editor for the project.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

CREATE INDEX IF NOT EXISTS idx_messages_created_at_retention
  ON public.messages (created_at);

SELECT cron.schedule(
  'delete-chat-messages-older-than-24-hours',
  '*/5 * * * *',
  'DELETE FROM public.messages WHERE created_at < NOW() - INTERVAL ''24 hours'';'
);
