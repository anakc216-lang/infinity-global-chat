CREATE TABLE IF NOT EXISTS public.chat_push_subscriptions (
  endpoint text PRIMARY KEY,
  subscription jsonb NOT NULL CHECK (jsonb_typeof(subscription) = 'object'),
  owner_device_id text NOT NULL CHECK (length(owner_device_id) BETWEEN 1 AND 128),
  owner_user_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.chat_push_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chat_push_subscriptions FROM anon, authenticated;
GRANT ALL ON public.chat_push_subscriptions TO service_role;

CREATE OR REPLACE FUNCTION public.dispatch_chat_push_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault, net
AS $$
DECLARE
  webhook_url text;
  webhook_secret text;
BEGIN
  SELECT decrypted_secret INTO webhook_url
  FROM vault.decrypted_secrets
  WHERE name = 'infinity_chat_push_webhook_url'
  LIMIT 1;

  SELECT decrypted_secret INTO webhook_secret
  FROM vault.decrypted_secrets
  WHERE name = 'infinity_chat_push_webhook_secret'
  LIMIT 1;

  IF COALESCE(webhook_url, '') = '' OR COALESCE(webhook_secret, '') = '' THEN
    RAISE WARNING 'Chat push is not configured: add the webhook URL and secret to Supabase Vault.';
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := webhook_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-push-webhook-secret', webhook_secret
    ),
    body := jsonb_build_object('record', to_jsonb(NEW)),
    timeout_milliseconds := 5000
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS dispatch_chat_push_after_message_insert ON public.messages;
CREATE TRIGGER dispatch_chat_push_after_message_insert
AFTER INSERT ON public.messages
FOR EACH ROW
EXECUTE FUNCTION public.dispatch_chat_push_notification();
