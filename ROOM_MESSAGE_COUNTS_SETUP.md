# Live message counts by country

Run [room-message-counts-migration.sql](./room-message-counts-migration.sql) once in the Supabase SQL Editor.

The migration adds a read-only RPC that returns grouped message totals without downloading all message rows. The country picker displays one live message total beside each country, refreshes the totals when opened, and updates immediately as messages arrive. This uses insert events only, so clearing the full messages table at the configured threshold does not broadcast 200,000 delete events to every user.

After running the migration, deploy the updated app. If the RPC has not been installed yet, the app logs the issue and keeps its local count display rather than blocking chat.

## Chat send/read delivery

For existing deployments, also run [chat-message-delivery-reliability-migration.sql](./chat-message-delivery-reliability-migration.sql) after the core messages and multilingual-edit migrations. It ensures chat clients can read visible messages, call the send RPC, and receive message changes through Realtime.

## Install-link click tracking

Run [app-install-rating-migration.sql](./app-install-rating-migration.sql) first if the `app_installations` table does not exist. Then run [app-install-click-tracking-migration.sql](./app-install-click-tracking-migration.sql) to store unique device/browser clicks on install-related controls. Deploy the updated app after both migrations. The install metrics display is hidden by default but continues recording; remove the `hidden` attribute from `#installMetrics` to show the counters again.
