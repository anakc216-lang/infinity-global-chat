BEGIN;

CREATE OR REPLACE FUNCTION public.has_active_pro_access(p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_user_id IS NOT NULL
    AND (auth.role() = 'service_role' OR p_user_id = auth.uid());
$$;

REVOKE ALL ON FUNCTION public.has_active_pro_access(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_active_pro_access(UUID) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
