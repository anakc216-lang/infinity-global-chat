-- Track unique PWA installations separately from install-button/link clicks.
-- Run after app-install-rating-migration.sql.

CREATE TABLE IF NOT EXISTS public.app_install_link_clicks (
  id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  device_id TEXT NOT NULL,
  link_type TEXT NOT NULL CHECK (
    link_type IN ('install_button', 'install_help', 'google_play', 'supported_browser')
  ),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT app_install_link_clicks_one_device_link UNIQUE (device_id, link_type)
);

-- Count unique browser/device taps per install option, not repeated taps.
CREATE INDEX IF NOT EXISTS app_install_link_clicks_created_at_idx
  ON public.app_install_link_clicks(created_at);

ALTER TABLE public.app_install_link_clicks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.app_install_link_clicks FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS "Block direct install link click access" ON public.app_install_link_clicks;
CREATE POLICY "Block direct install link click access"
  ON public.app_install_link_clicks
  FOR ALL TO anon, authenticated
  USING (FALSE)
  WITH CHECK (FALSE);

CREATE OR REPLACE FUNCTION public.get_app_install_metrics()
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT jsonb_build_object(
    'total_installs', (SELECT count(*)::INTEGER FROM public.app_installations),
    'total_install_link_clicks', (SELECT count(DISTINCT device_id)::INTEGER FROM public.app_install_link_clicks)
  );
$$;

CREATE OR REPLACE FUNCTION public.record_app_install_link_click(
  p_device_id TEXT,
  p_link_type TEXT
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_device_id TEXT := NULLIF(btrim(p_device_id), '');
  v_link_type TEXT := NULLIF(btrim(p_link_type), '');
BEGIN
  IF v_device_id IS NULL OR length(v_device_id) > 200 THEN
    RAISE EXCEPTION 'A valid device identifier is required';
  END IF;

  IF v_link_type NOT IN ('install_button', 'install_help', 'google_play', 'supported_browser') THEN
    RAISE EXCEPTION 'Unsupported install link type';
  END IF;

  INSERT INTO public.app_install_link_clicks(device_id, link_type)
  VALUES (v_device_id, v_link_type)
  ON CONFLICT (device_id, link_type) DO NOTHING;

  RETURN jsonb_build_object(
    'total_install_link_clicks',
    (SELECT count(DISTINCT device_id)::INTEGER FROM public.app_install_link_clicks)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_app_install_metrics() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_app_install_link_click(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_install_metrics() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.record_app_install_link_click(TEXT, TEXT) TO anon, authenticated;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.app_install_link_clicks;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END;
$$;

NOTIFY pgrst, 'reload schema';
