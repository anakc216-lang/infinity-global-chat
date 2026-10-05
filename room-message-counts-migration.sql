CREATE OR REPLACE FUNCTION public.get_message_counts_by_room()
RETURNS TABLE (room text, message_count bigint)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  SELECT messages.room, count(*)::bigint
  FROM public.messages AS messages
  GROUP BY messages.room;
$$;

REVOKE ALL ON FUNCTION public.get_message_counts_by_room() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_message_counts_by_room() TO anon, authenticated;
