-- MODERATION: REPORTS, ADMIN ACTIONS, AND AUDIT LOG
-- Run after the existing messages/profile and Speed Job migrations.
-- Admin bootstrap: INSERT INTO public.admin_users (user_id) VALUES ('AUTH_USER_UUID');

CREATE TABLE IF NOT EXISTS public.admin_users (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION public.is_admin(p_user_id UUID DEFAULT auth.uid())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_user_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = p_user_id);
$$;

REVOKE ALL ON FUNCTION public.is_admin(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_admin(UUID) TO anon, authenticated;

ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS is_hidden BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS hidden_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS hidden_by UUID REFERENCES auth.users(id);

DROP POLICY IF EXISTS "Allow read all messages" ON public.messages;
CREATE POLICY "Read visible messages"
  ON public.messages FOR SELECT
  TO anon, authenticated
  USING (is_hidden = FALSE);

ALTER TABLE public.speed_job_posts
  ADD COLUMN IF NOT EXISTS hidden_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS hidden_by UUID REFERENCES auth.users(id);

DROP POLICY IF EXISTS "Speed jobs read public" ON public.speed_job_posts;
CREATE POLICY "Read visible speed jobs"
  ON public.speed_job_posts FOR SELECT
  TO anon, authenticated
  USING (hidden_at IS NULL);

-- The existing SECURITY DEFINER listing RPC must also exclude hidden posts.
CREATE OR REPLACE FUNCTION public.get_speed_job_posts(p_post_type TEXT DEFAULT NULL)
RETURNS TABLE (
  id UUID, room TEXT, owner_device_id TEXT, owner_username TEXT, owner_avatar TEXT,
  post_type TEXT, job_type TEXT, location TEXT, contact_info TEXT, social_links TEXT[],
  pay TEXT, schedule_text TEXT, pack_need INTEGER, gender TEXT, description TEXT,
  status TEXT, created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.room, s.owner_device_id, s.owner_username, s.owner_avatar,
    s.post_type, s.job_type, s.location, s.contact_info, s.social_links, s.pay,
    s.schedule_text, s.pack_need, s.gender, s.description, s.status,
    s.created_at, s.updated_at
  FROM public.speed_job_posts s
  WHERE s.hidden_at IS NULL
    AND (p_post_type IS NULL OR s.post_type = p_post_type)
  ORDER BY s.created_at DESC;
$$;

CREATE TABLE IF NOT EXISTS public.moderation_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  target_type TEXT NOT NULL CHECK (target_type IN ('message', 'speed_job')),
  target_id UUID NOT NULL,
  reason TEXT NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 1 AND 500),
  reporter_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  reporter_device_id TEXT,
  reporter_username TEXT,
  target_snapshot JSONB NOT NULL DEFAULT '{}'::JSONB,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  resolved_at TIMESTAMPTZ,
  resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_open_moderation_report
  ON public.moderation_reports (target_type, target_id, reporter_user_id, reporter_device_id)
  WHERE status = 'open';
CREATE INDEX IF NOT EXISTS idx_moderation_reports_status_created
  ON public.moderation_reports (status, created_at DESC);

CREATE TABLE IF NOT EXISTS public.moderation_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  report_id UUID REFERENCES public.moderation_reports(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN ('hide', 'delete', 'resolve')),
  target_type TEXT,
  target_id UUID,
  details JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_moderation_audit_created
  ON public.moderation_audit_logs (created_at DESC);

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.moderation_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read admin users" ON public.admin_users;
CREATE POLICY "Admins read admin users" ON public.admin_users FOR SELECT TO authenticated
  USING (public.is_admin());
DROP POLICY IF EXISTS "Admins read reports" ON public.moderation_reports;
CREATE POLICY "Admins read reports" ON public.moderation_reports FOR SELECT TO authenticated
  USING (public.is_admin());
DROP POLICY IF EXISTS "Admins read audit logs" ON public.moderation_audit_logs;
CREATE POLICY "Admins read audit logs" ON public.moderation_audit_logs FOR SELECT TO authenticated
  USING (public.is_admin());

REVOKE ALL ON TABLE public.admin_users, public.moderation_reports, public.moderation_audit_logs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.admin_users, public.moderation_reports, public.moderation_audit_logs TO authenticated;

CREATE OR REPLACE FUNCTION public.submit_moderation_report(
  p_target_type TEXT,
  p_target_id UUID,
  p_reason TEXT,
  p_reporter_device_id TEXT DEFAULT NULL,
  p_reporter_username TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_snapshot JSONB;
  v_report_id UUID;
BEGIN
  IF p_target_type NOT IN ('message', 'speed_job') OR p_target_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Invalid moderation target');
  END IF;
  IF p_reason IS NULL OR char_length(btrim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Reason is required');
  END IF;

  IF p_target_type = 'message' THEN
    SELECT jsonb_build_object('id', id, 'room', room, 'username', username, 'content', content)
      INTO v_snapshot FROM public.messages WHERE id = p_target_id;
  ELSE
    SELECT jsonb_build_object('id', id, 'room', room, 'owner_username', owner_username,
      'post_type', post_type, 'job_type', job_type, 'description', description)
      INTO v_snapshot FROM public.speed_job_posts WHERE id = p_target_id AND hidden_at IS NULL;
  END IF;

  IF v_snapshot IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'error', 'Content not found');
  END IF;

  INSERT INTO public.moderation_reports (
    target_type, target_id, reason, reporter_user_id, reporter_device_id,
    reporter_username, target_snapshot
  ) VALUES (
    p_target_type, p_target_id, btrim(p_reason), auth.uid(),
    NULLIF(btrim(p_reporter_device_id), ''), NULLIF(btrim(p_reporter_username), ''), v_snapshot
  ) ON CONFLICT (target_type, target_id, reporter_user_id, reporter_device_id)
    WHERE status = 'open' DO NOTHING
  RETURNING id INTO v_report_id;

  RETURN jsonb_build_object('success', TRUE, 'report_id', v_report_id,
    'duplicate', v_report_id IS NULL);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_moderation_reports(p_status TEXT DEFAULT 'open')
RETURNS SETOF public.moderation_reports
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  RETURN QUERY SELECT * FROM public.moderation_reports
    WHERE p_status IS NULL OR status = p_status ORDER BY created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.moderate_report(
  p_report_id UUID,
  p_action TEXT,
  p_resolution TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_report public.moderation_reports;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'Admin access required'; END IF;
  IF p_action NOT IN ('hide', 'delete', 'resolve') THEN
    RAISE EXCEPTION 'Invalid moderation action';
  END IF;

  SELECT * INTO v_report FROM public.moderation_reports WHERE id = p_report_id FOR UPDATE;
  IF v_report.id IS NULL THEN RAISE EXCEPTION 'Report not found'; END IF;

  IF p_action = 'hide' THEN
    IF v_report.target_type = 'message' THEN
      UPDATE public.messages SET is_hidden = TRUE, hidden_at = NOW(), hidden_by = auth.uid()
        WHERE id = v_report.target_id;
    ELSE
      UPDATE public.speed_job_posts SET hidden_at = NOW(), hidden_by = auth.uid(), status = 'HIDDEN'
        WHERE id = v_report.target_id;
    END IF;
  ELSIF p_action = 'delete' THEN
    IF v_report.target_type = 'message' THEN
      DELETE FROM public.messages WHERE id = v_report.target_id;
    ELSE
      DELETE FROM public.speed_job_posts WHERE id = v_report.target_id;
    END IF;
  END IF;

  UPDATE public.moderation_reports SET status = 'resolved', resolved_at = NOW(),
    resolved_by = auth.uid(), resolution = COALESCE(NULLIF(btrim(p_resolution), ''), p_action)
    WHERE id = p_report_id;

  INSERT INTO public.moderation_audit_logs
    (admin_user_id, report_id, action, target_type, target_id, details)
  VALUES (auth.uid(), p_report_id, p_action, v_report.target_type, v_report.target_id,
    jsonb_build_object('resolution', p_resolution, 'previous_status', v_report.status));

  RETURN jsonb_build_object('success', TRUE, 'action', p_action, 'report_id', p_report_id);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_moderation_report(TEXT, UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_moderation_reports(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.moderate_report(UUID, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_moderation_report(TEXT, UUID, TEXT, TEXT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_moderation_reports(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.moderate_report(UUID, TEXT, TEXT) TO authenticated;

SELECT 'MODERATION SQL READY' AS status;
