# Infinity Chat Pro Access Policy

## 1. Product

Infinity Chat Pro Access is an optional digital service feature. A successful payment grants the purchaser permission to send messages through the app for one year from the time the payment is verified.

The price is RM35 for three months of access. The plan renews automatically every three months only after the purchaser gives clear consent to recurring billing. The purchaser must be shown the renewal price, renewal interval, cancellation method, and payment-provider terms before subscribing.

## 2. Message access

Users may browse rooms and open links without Pro Access. Only users with a verified active Pro Access entitlement, or an authorized administrator account, may send messages.

Access is granted only after the payment provider confirms a captured/settled payment and the server records the entitlement. A client-side flag, screenshot, edited request, or browser storage value does not grant access.

## 3. Simulated online display

All online figures labelled `SIMULATED ONLINE` are interface simulations. They are not a statement of actual users, traffic, audience size, reach, impressions, sales, or business results. Payment does not purchase or guarantee any number of users, views, replies, conversions, or engagement.

## 4. Payment and activation

Before payment, the app must show the price, duration, currency, service description, renewal status, refund terms, privacy notice, and a clear confirmation action.

The app must not charge a user merely because the user remains on a page for one minute. A one-minute timer may display the offer, but payment requires an explicit user action and the payment provider's own confirmation flow.

Payment credentials are handled by the payment provider. The app must not store card numbers, CVV values, passwords, or payment secrets.

## 5. Refunds and cancellation

The purchaser may cancel automatic renewal at any time through the published cancellation method. Cancellation stops the next renewal but does not shorten the already-paid access period unless a legally required refund applies.

Payments are non-refundable after successful activation except where a refund is required by applicable consumer-protection law, payment-provider rules, a duplicate charge, a failed activation, or a decision made by the service operator. The operator may publish a separate support and refund process.

This clause is not intended to remove any mandatory statutory right.

## 6. Administrator access

Authorized administrators may be exempted from the Pro payment requirement for operational purposes. Administrator status must be checked server-side using a controlled administrator identity or role. It must never be based only on a visible button, username text, or local browser storage.

The initial administrator identity must be configured privately in the server/database environment and must not be committed to the repository.

## 7. Acceptable use

Users must not use the service for scams, phishing, malware, harassment, illegal activity, spam, impersonation, or unlawful content. The operator may restrict, suspend, or remove access when necessary for safety, abuse prevention, legal compliance, or platform integrity.

Pro Access does not guarantee message delivery, uninterrupted availability, account recovery, or preservation of user content.

## 8. Privacy and records

The service may process account identifiers, device identifiers, entitlement dates, payment-provider identifiers, messages, reports, and technical logs needed for authentication, access control, moderation, fraud prevention, support, and legal compliance.

Only the minimum payment records needed to verify and support an entitlement should be retained. Payment secrets and sensitive card data must not be stored by the app.

## 9. Disclaimer

The service is provided as a digital communication feature and may be changed, interrupted, limited, or discontinued. To the maximum extent permitted by law, the operator is not responsible for indirect loss, lost profits, lost opportunities, third-party links, user-generated content, or outcomes based on simulated online figures.

Nothing in this policy excludes liability that cannot legally be excluded.

## 10. Payment flows

Only these two payment flows are permitted:

1. **Global milestone payment: RM30**. This remains the existing one-time Razorpay milestone flow. It must not grant Pro message access unless explicitly recorded as a separate entitlement by the server.
2. **Pro Access subscription: RM35 every 3 months**. This is the only flow that grants three months of message-sending access. It must use a Razorpay subscription/recurring-billing flow, not the one-time milestone order endpoint.

The two flows must use separate plan identifiers, receipts, database records, webhooks, and server verification rules. A milestone payment must never be treated as a three-month Pro subscription, and a Pro payment must never be treated as a milestone payment.

Three-month access begins only after the first payment is captured and the server records the entitlement. Each renewal extends access only after a verified recurring payment webhook. Failed, cancelled, paused, refunded, or disputed renewals must not extend access.

## 11. Support

Support contact: publish a monitored support email or official support channel before accepting payment.

## Implementation requirements

- Verify every payment server-side with Razorpay and a signed webhook.
- Record an entitlement with `starts_at`, `expires_at`, provider order ID, provider payment ID, currency, amount, and user ID.
- Enforce message sending in the Supabase RPC, not only in the browser.
- Use an administrator role or server-controlled administrator allow-list.
- Keep `SIMULATED ONLINE` visible wherever simulated figures are shown.
- Test duplicate payments, failed payments, expired access, webhook retries, revoked access, admin access, and unauthenticated users.

This document is an operational template, not legal advice. Obtain a local legal review before launching paid access, especially for consumer rights, recurring billing consent, taxes, privacy, payment rules, and digital-service refunds.
