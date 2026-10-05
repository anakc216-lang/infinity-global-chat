BEGIN;

LOCK TABLE public.messages IN SHARE ROW EXCLUSIVE MODE;

CREATE TABLE IF NOT EXISTS public.message_retention_state (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  message_count bigint NOT NULL CHECK (message_count >= 0)
);

ALTER TABLE public.message_retention_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.message_retention_state FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.message_retention_state TO service_role;

INSERT INTO public.message_retention_state (singleton, message_count)
SELECT true, count(*) FROM public.messages
ON CONFLICT (singleton) DO UPDATE
SET message_count = EXCLUDED.message_count;

CREATE OR REPLACE FUNCTION public.clear_all_messages_at_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  current_message_count bigint;
  deleted_message_count bigint;
BEGIN
  UPDATE public.message_retention_state
  SET message_count = message_count + 1
  WHERE singleton = true
  RETURNING message_count INTO current_message_count;

  IF current_message_count IS NULL THEN
    RAISE EXCEPTION 'Message retention counter is not initialized';
  END IF;

  IF current_message_count >= 200000 THEN
    PERFORM set_config('app.message_cleanup_in_progress', 'on', true);
    DELETE FROM public.messages;
    GET DIAGNOSTICS deleted_message_count = ROW_COUNT;
    PERFORM set_config('app.message_cleanup_in_progress', 'off', true);

    UPDATE public.message_retention_state
    SET message_count = 0
    WHERE singleton = true;

    RAISE LOG 'Automatic message cleanup deleted % rows after reaching the 200000-message limit.',
      deleted_message_count;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_all_messages_at_limit() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.decrement_message_retention_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  current_message_count bigint;
BEGIN
  IF current_setting('app.message_cleanup_in_progress', true) = 'on' THEN
    RETURN OLD;
  END IF;

  UPDATE public.message_retention_state
  SET message_count = GREATEST(0, message_count - 1)
  WHERE singleton = true
  RETURNING message_count INTO current_message_count;

  IF current_message_count IS NULL THEN
    RAISE EXCEPTION 'Message retention counter is not initialized';
  END IF;

  RETURN OLD;
END;
$$;

REVOKE ALL ON FUNCTION public.decrement_message_retention_count() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS decrement_message_retention_count_after_delete ON public.messages;
CREATE TRIGGER decrement_message_retention_count_after_delete
AFTER DELETE ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.decrement_message_retention_count();

DROP TRIGGER IF EXISTS clear_all_messages_at_limit_after_insert ON public.messages;
CREATE TRIGGER clear_all_messages_at_limit_after_insert
AFTER INSERT ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.clear_all_messages_at_limit();

COMMIT;
