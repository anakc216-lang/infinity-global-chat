-- Infinity Chat first-touch referral attribution.
-- Run after the existing profile/auth migrations.

-- Canonical merchant/referral registry. Keep this separate from attribution
-- events so every QR code has a real, searchable merchant row.
CREATE TABLE IF NOT EXISTS public.referral_merchants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_code TEXT NOT NULL,
  merchant_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT referral_merchants_status_check
    CHECK (status IN ('active', 'inactive'))
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'referral_merchants_referral_code_key'
      AND conrelid = 'public.referral_merchants'::regclass
  ) THEN
    ALTER TABLE public.referral_merchants
      ADD CONSTRAINT referral_merchants_referral_code_key UNIQUE (referral_code);
  END IF;
END $$;

INSERT INTO public.referral_merchants (referral_code, merchant_name, status, is_active)
SELECT
  'KEDAI' || LPAD(number::TEXT, 3, '0'),
  'KEDAI' || LPAD(number::TEXT, 3, '0'),
  'active',
  TRUE
FROM generate_series(1, 30) AS numbers(number)
ON CONFLICT (referral_code) DO UPDATE
SET merchant_name = EXCLUDED.merchant_name,
    status = 'active',
    is_active = TRUE,
    updated_at = CURRENT_TIMESTAMP;

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

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'referral_attributions_referral_id_fkey'
      AND conrelid = 'public.referral_attributions'::regclass
  ) THEN
    ALTER TABLE public.referral_attributions
      ADD CONSTRAINT referral_attributions_referral_id_fkey
      FOREIGN KEY (referral_id)
      REFERENCES public.referral_merchants(referral_code);
  END IF;
END $$;

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
  IF NOT EXISTS (
    SELECT 1
    FROM public.referral_merchants
    WHERE referral_code = v_referral_id
      AND status = 'active'
      AND is_active = TRUE
  )
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

DO $$
DECLARE
  v_merchant_count INTEGER;
  v_active_count INTEGER;
BEGIN
  SELECT COUNT(*), COUNT(*) FILTER (WHERE status = 'active' AND is_active = TRUE)
  INTO v_merchant_count, v_active_count
  FROM public.referral_merchants
  WHERE referral_code ~ '^KEDAI(00[1-9]|0[12][0-9]|030)$';

  IF v_merchant_count <> 30 OR v_active_count <> 30 THEN
    RAISE EXCEPTION 'Referral merchant seed verification failed: expected 30 active KEDAI rows, found % rows (% active)',
      v_merchant_count, v_active_count;
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';
