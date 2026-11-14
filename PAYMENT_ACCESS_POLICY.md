# Infinity Chat Free Access Policy

## 1. Product

All app features are free to use. No Pro subscription or lifetime purchase is required for country rooms, messaging, MyVideos, or Speed Job. New in-app payment orders are disabled.

## 2. Message access

The client creates a Supabase anonymous-auth session when needed so users can use authenticated database APIs without registering. The `free-pro-access-migration.sql` migration makes the server-side access check allow the current authenticated user. Supabase Anonymous Sign-Ins must be enabled. Existing safety, moderation, and database policies still apply.

## 3. Simulated online display

All online figures labelled `SIMULATED ONLINE` are interface simulations. They are not a statement of actual users, traffic, audience size, reach, impressions, sales, or business results. No number of users, views, replies, conversions, or engagement is guaranteed.

## 4. Existing subscriptions and payments

Making features free does not cancel subscriptions already created with Razorpay. Existing subscribers must use the in-app cancellation control to stop future renewals; cancellation may take effect at the end of the current billing period. If the app cannot find an older subscription, cancel it directly with Razorpay. Contact the payment provider about refunds or charges already made. Existing webhooks and verification routes remain only to reconcile legacy transactions.

The app and server must not create new Pro subscription, lifetime, or milestone payment orders. The cancellation route remains available for existing subscriptions.

## 5. Administrator access

Administrator status must be checked server-side using a controlled administrator identity or role. It must never be based only on a visible button, username text, or local browser storage. Administrator credentials must not be committed to the repository.

## 6. Acceptable use

Users must not use the service for scams, phishing, malware, harassment, illegal activity, spam, impersonation, or unlawful content. The operator may restrict, suspend, or remove access when necessary for safety, abuse prevention, legal compliance, or platform integrity.

Free access does not guarantee message delivery, uninterrupted availability, account recovery, or preservation of user content.

## 7. Privacy and records

The service may process account identifiers, device identifiers, entitlement dates, payment-provider identifiers, messages, reports, and technical logs needed for authentication, access control, moderation, fraud prevention, support, and legal compliance.

Only the minimum payment records needed to verify and support an entitlement should be retained. Payment secrets and sensitive card data must not be stored by the app.

## 8. Disclaimer

The service is provided as a digital communication feature and may be changed, interrupted, limited, or discontinued. To the maximum extent permitted by law, the operator is not responsible for indirect loss, lost profits, lost opportunities, third-party links, user-generated content, or outcomes based on simulated online figures.

Nothing in this policy excludes liability that cannot legally be excluded.

## 9. Legacy payment handling

New payment-order routes return HTTP 410 and the frontend no longer offers Pro checkout. The legacy cancellation route and signed Razorpay webhook remain so existing recurring subscriptions can be cancelled and old payments can be reconciled. Keep payment credentials server-side and never commit them.

Apply the existing schema migrations as required by the project, then apply `free-pro-access-migration.sql` last so it overrides the previous paid-access check. Deploy the updated frontend and server after applying the SQL migration. This repository change alone does not update a live Supabase project or deployed service.

## 10. Support

Publish a monitored support channel for questions about existing subscriptions and charges.

## Implementation requirements

- Do not create new Pro or milestone payment orders.
- Keep the legacy cancellation route and signed webhook for existing subscriptions and transaction reconciliation.
- Apply `free-pro-access-migration.sql` after the existing access-control migrations.
- Keep message sending and feature access enforced by Supabase policies and RPCs, not only by the browser.
- Use an administrator role or server-controlled administrator allow-list.
- Keep `SIMULATED ONLINE` visible wherever simulated figures are shown.
- Verify that anonymous and registered users can access all intended features after the migration, and that users cannot act as another user.

This document is an operational policy, not legal advice. Existing subscription renewals may continue until cancelled with the payment provider.
