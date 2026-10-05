# Push notification setup

Push notifications require configuration in both the backend host and Supabase. Until these steps are complete, the in-app sound works for realtime messages, but notifications cannot be delivered after the app is closed.

## 1. Configure the backend

Generate a VAPID key pair from the repository:

```powershell
npx web-push generate-vapid-keys
node -e "process.stdout.write(require('crypto').randomBytes(32).toString('base64url'))"
```

The first command prints the VAPID public/private key pair; the second prints a separate random value for `PUSH_WEBHOOK_SECRET`.

Set these environment variables on the Node backend deployment. Keep the private key and webhook secret private:

- `VAPID_PUBLIC_KEY`: generated public key
- `VAPID_PRIVATE_KEY`: generated private key
- `VAPID_SUBJECT`: a contact URI, for example `mailto:admin@example.com`
- `PUSH_WEBHOOK_SECRET`: a new random secret shared only with Supabase Vault
- `PUSH_ALLOWED_ORIGINS`: comma-separated origins allowed to manage subscriptions; defaults to `https://infinity-global-chat.onrender.com`
- `SUPABASE_SERVICE_ROLE_KEY`: the existing server-only Supabase service role key
- `SUPABASE_ANON_KEY`: the existing Supabase anon key, used to associate authenticated installations with their account

Do not put private keys or webhook secrets in client code or commit them to the repository.

## 2. Apply the database migration

Run [chat-push-notifications-migration.sql](./chat-push-notifications-migration.sql) in the Supabase SQL editor. It creates a private subscription table and sends a webhook for every inserted message. All subscribers are notified regardless of room; the sender's own devices are excluded.

## 3. Store the webhook credentials in Supabase Vault

Use the same `PUSH_WEBHOOK_SECRET` value configured on the backend. Store the backend URL that serves `/api/push/notify`:

```sql
select vault.create_secret(
  'https://infinity-global-chat-backend-2026.onrender.com/api/push/notify',
  'infinity_chat_push_webhook_url'
);

select vault.create_secret(
  '<the same PUSH_WEBHOOK_SECRET configured on the backend>',
  'infinity_chat_push_webhook_secret'
);
```

If the backend URL changes, update the Vault secret. The migration relies on Supabase's `pg_net` and Vault extensions.

## 4. Enable notifications per device

Deploy the updated app and backend. Each user must open the app, tap **PUSH OFF**, and allow browser notifications. The browser requires this explicit permission; users can turn notifications off from the same button or the browser's notification settings.

When a push arrives while the app is closed or in the background, the notification identifies the sender and chat room, and the browser/operating system uses its normal notification sound. Device silent mode, notification settings, battery restrictions, browser support, and network availability can prevent or mute delivery; web apps cannot force audio through those system controls. The in-app chat sound toggle only controls sound while the app is open.
