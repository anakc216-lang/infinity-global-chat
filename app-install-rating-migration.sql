-- Infinity Chat: persistent joined-user counter and one-rating-per-user/device.
-- Run after the existing Supabase migrations.

CREATE TABLE IF NOT EXISTS public.app_installations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT app_installations_one_identity CHECK (user_id IS NOT NULL OR device_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS app_installations_user_id_unique
  ON public.app_installations(user_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS app_installations_device_id_unique
  ON public.app_installations(device_id) WHERE device_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS app_installations_created_at_idx
  ON public.app_installations(created_at);

CREATE TABLE IF NOT EXISTS public.app_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id TEXT,
  rating SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT app_reviews_one_identity CHECK (user_id IS NOT NULL OR device_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS app_reviews_user_id_unique
  ON public.app_reviews(user_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS app_reviews_device_id_unique
  ON public.app_reviews(device_id) WHERE device_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS app_reviews_rating_idx ON public.app_reviews(rating);

ALTER TABLE public.app_installations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Block direct app installation reads" ON public.app_installations;
CREATE POLICY "Block direct app installation reads"
  ON public.app_installations FOR SELECT TO anon, authenticated USING (false);
DROP POLICY IF EXISTS "Block direct app installation writes" ON public.app_installations;
CREATE POLICY "Block direct app installation writes"
  ON public.app_installations FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS "Block direct app review reads" ON public.app_reviews;
CREATE POLICY "Block direct app review reads"
  ON public.app_reviews FOR SELECT TO anon, authenticated USING (false);
DROP POLICY IF EXISTS "Block direct app review writes" ON public.app_reviews;
CREATE POLICY "Block direct app review writes"
  ON public.app_reviews FOR ALL TO anon, authenticated USING (false) WITH CHECK (false);

-- Define the read-only aggregate functions before the write RPCs that call them.
CREATE OR REPLACE FUNCTION public.get_app_install_stats()
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object('total_installs', count(*)::INTEGER)
  FROM public.app_installations;
$$;

CREATE OR REPLACE FUNCTION public.get_app_review_stats(p_device_id TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_counts JSONB;
  v_current SMALLINT;
  v_user_id UUID := auth.uid();
  v_device_id TEXT := NULLIF(trim(p_device_id), '');
BEGIN
  SELECT COALESCE(jsonb_object_agg(rating::TEXT, rating_count), '{}'::JSONB)
    INTO v_counts
    FROM (
      SELECT rating, count(*)::INTEGER AS rating_count
      FROM public.app_reviews
      GROUP BY rating
    ) grouped;

  IF v_user_id IS NOT NULL THEN
    SELECT rating INTO v_current FROM public.app_reviews WHERE user_id = v_user_id;
  ELSIF v_device_id IS NOT NULL THEN
    SELECT rating INTO v_current FROM public.app_reviews WHERE device_id = v_device_id;
  END IF;

  RETURN jsonb_build_object('counts', v_counts, 'my_rating', v_current);
END;
$$;

CREATE OR REPLACE FUNCTION public.register_app_installation(p_device_id TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_device_id TEXT := NULLIF(trim(p_device_id), '');
BEGIN
  IF v_user_id IS NULL AND v_device_id IS NULL THEN
    RAISE EXCEPTION 'A device identifier is required';
  END IF;

  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.app_installations (user_id)
    VALUES (v_user_id)
    ON CONFLICT (user_id) WHERE user_id IS NOT NULL DO NOTHING;
    DELETE FROM public.app_installations
    WHERE device_id = v_device_id AND user_id IS NULL;
    UPDATE public.app_reviews
    SET user_id = v_user_id, device_id = NULL, updated_at = now()
    WHERE device_id = v_device_id
      AND user_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM public.app_reviews WHERE user_id = v_user_id);
    DELETE FROM public.app_reviews
    WHERE device_id = v_device_id AND user_id IS NULL;
  ELSE
    INSERT INTO public.app_installations (device_id)
    VALUES (v_device_id)
    ON CONFLICT (device_id) WHERE device_id IS NOT NULL DO NOTHING;
  END IF;

  RETURN public.get_app_install_stats();
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_app_review(p_device_id TEXT, p_rating SMALLINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_device_id TEXT := NULLIF(trim(p_device_id), '');
BEGIN
  IF p_rating IS NULL OR p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Rating must be between 1 and 5';
  END IF;
  IF v_user_id IS NULL AND v_device_id IS NULL THEN
    RAISE EXCEPTION 'A device identifier is required';
  END IF;

  IF v_user_id IS NOT NULL THEN
    INSERT INTO public.app_reviews (user_id, rating)
    VALUES (v_user_id, p_rating)
    ON CONFLICT (user_id) WHERE user_id IS NOT NULL
    DO UPDATE SET rating = EXCLUDED.rating, updated_at = now();
    DELETE FROM public.app_reviews
    WHERE device_id = v_device_id AND user_id IS NULL;
  ELSE
    INSERT INTO public.app_reviews (device_id, rating)
    VALUES (v_device_id, p_rating)
    ON CONFLICT (device_id) WHERE device_id IS NOT NULL
    DO UPDATE SET rating = EXCLUDED.rating, updated_at = now();
  END IF;

  RETURN public.get_app_review_stats(v_device_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_app_installation(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_app_review(TEXT, SMALLINT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_app_install_stats() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_app_review_stats(TEXT) TO anon, authenticated;

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.app_installations;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.app_reviews;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
