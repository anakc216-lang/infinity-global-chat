-- Infinity Chat first-touch referral attribution.
-- Run after the existing profile/auth migrations.

CREATE TABLE IF NOT EXISTS public.referral_attributions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_id TEXT NOT NULL,
  device_id TEXT NOT NULL UNIQUE,
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  landing_path TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT referral_attributions_referral_id_check
    CHECK (referral_id ~ '^KEDAI(00[1-9]|0[12][0-9]|030)$')
);

CREATE INDEX IF NOT EXISTS idx_referral_attributions_referral_id
  ON public.referral_attributions(referral_id);

CREATE INDEX IF NOT EXISTS idx_referral_attributions_user_id
  ON public.referral_attributions(user_id);

ALTER TABLE public.referral_attributions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Referral attribution is not directly readable" ON public.referral_attributions;
CREATE POLICY "Referral attribution is not directly readable"
  ON public.referral_attributions FOR SELECT
  TO anon, authenticated
  USING (FALSE);

DROP POLICY IF EXISTS "Referral attribution is not directly insertable" ON public.referral_attributions;
CREATE POLICY "Referral attribution is not directly insertable"
  ON public.referral_attributions FOR INSERT
  TO anon, authenticated
  WITH CHECK (FALSE);

DROP POLICY IF EXISTS "Referral attribution is not directly updateable" ON public.referral_attributions;
CREATE POLICY "Referral attribution is not directly updateable"
  ON public.referral_attributions FOR UPDATE
  TO anon, authenticated
  USING (FALSE)
  WITH CHECK (FALSE);

CREATE OR REPLACE FUNCTION public.capture_referral_attribution(
  p_referral_id TEXT,
  p_device_id TEXT,
  p_landing_path TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_referral_id TEXT := upper(btrim(p_referral_id));
  v_device_id TEXT := btrim(p_device_id);
  v_user_id UUID := auth.uid();
  v_attribution public.referral_attributions;
BEGIN
  IF v_referral_id !~ '^KEDAI(00[1-9]|0[12][0-9]|030)$'
     OR NULLIF(v_device_id, '') IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid referral attribution');
  END IF;

  SELECT * INTO v_attribution
  FROM public.referral_attributions
  WHERE device_id = v_device_id
     OR (v_user_id IS NOT NULL AND user_id = v_user_id)
  ORDER BY first_seen_at ASC
  LIMIT 1;

  IF v_attribution.id IS NULL THEN
    INSERT INTO public.referral_attributions (referral_id, device_id, user_id, landing_path)
    VALUES (v_referral_id, v_device_id, v_user_id, left(NULLIF(btrim(p_landing_path), ''), 500))
    RETURNING * INTO v_attribution;
  ELSE
    UPDATE public.referral_attributions
    SET user_id = COALESCE(v_attribution.user_id, v_user_id),
        last_seen_at = CURRENT_TIMESTAMP,
        landing_path = COALESCE(v_attribution.landing_path, left(NULLIF(btrim(p_landing_path), ''), 500)),
        updated_at = CURRENT_TIMESTAMP
    WHERE id = v_attribution.id
    RETURNING * INTO v_attribution;
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'attribution_id', v_attribution.id,
    'referral_id', v_attribution.referral_id,
    'first_seen_at', v_attribution.first_seen_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.capture_referral_attribution(TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.capture_referral_attribution(TEXT, TEXT, TEXT) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
