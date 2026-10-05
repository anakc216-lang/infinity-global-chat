# Live message counts by country

Run [room-message-counts-migration.sql](./room-message-counts-migration.sql) once in the Supabase SQL Editor.

The migration adds a read-only RPC that returns grouped message totals without downloading all message rows. The country picker displays one live message total beside each country, refreshes the totals when opened, and updates immediately as messages arrive. This uses insert events only, so clearing the full messages table at the configured threshold does not broadcast 200,000 delete events to every user.

After running the migration, deploy the updated app. If the RPC has not been installed yet, the app logs the issue and keeps its local count display rather than blocking chat.
