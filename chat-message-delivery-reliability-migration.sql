-- Ensure chat clients can read visible messages and receive message changes.
-- Run after the core messages and multilingual-edit migrations.

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON TABLE public.messages TO anon, authenticated;

DROP POLICY IF EXISTS "Allow read all messages" ON public.messages;
DROP POLICY IF EXISTS "Chat messages readable by clients" ON public.messages;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'messages'
      AND column_name = 'is_hidden'
  ) THEN
    EXECUTE 'CREATE POLICY "Chat messages readable by clients"
      ON public.messages FOR SELECT
      TO anon, authenticated
      USING (is_hidden = FALSE)';
  ELSE
    EXECUTE 'CREATE POLICY "Chat messages readable by clients"
      ON public.messages FOR SELECT
      TO anon, authenticated
      USING (TRUE)';
  END IF;
END;
$$;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_and_send_message_v2(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
