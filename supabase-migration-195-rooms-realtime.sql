-- Enable all 195 country rooms and realtime message delivery.
-- Run this once on an existing Supabase project.

DO $$
DECLARE
  constraint_rec RECORD;
BEGIN
  FOR constraint_rec IN
    SELECT cl.relname AS table_name, c.conname
    FROM pg_constraint c
    INNER JOIN pg_class cl ON cl.oid = c.conrelid
    INNER JOIN pg_namespace ns ON ns.oid = cl.relnamespace
    WHERE ns.nspname = 'public'
      AND cl.relname IN ('messages', 'device_usage')
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%room%'
  LOOP
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I', constraint_rec.table_name, constraint_rec.conname);
  END LOOP;
END $$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
