# WhatsApp Reminder Pro

WhatsApp Reminder Pro is the first standalone app in WhatsApp Business Toolkit. The product is intended to be free for businesses. Customers will own their Meta WhatsApp Business accounts and pay Meta directly for any applicable messaging fees. This repository does not collect card details or operator-funded messaging charges.

## Current implementation status

This is an active development build, not a production release. The responsive dashboard currently implements local-preview contacts, CSV import/export, consent and opt-out fields, template editing and previews, reminder CRUD and recurring options, manual click-to-chat links, message history, record-based analytics, light/dark mode, and mobile navigation. Local preview data is stored in the browser and must not be used for real customer information.

The Neon project `whatsapp-reminder-pro` has Neon Auth and the Neon Data API provisioned. Versioned SQL migrations are in `neon/migrations`. The database includes tenant/business memberships, contacts and consent, templates, reminders, durable run records, message history, connection credential fields, RLS policies, tenant-scoped foreign keys, and privacy-safe audit triggers. The initial tenant isolation check was run against the live database with two synthetic tenants: each authenticated role read only its own contact, and an attempted cross-tenant update affected no rows. Temporary test rows were removed within the same transaction. The audit handling fixes for missing JWTs and business cascade deletion are in migrations `0004` and `0005`.

Neon Auth/Data API wiring exists in `lib/neon.ts` and the dashboard. The live Auth configuration currently has email verification disabled (`require_email_verification=false`), so email verification does not meet the product requirement yet. Registration, verification, reset/recovery, business provisioning, and real authenticated CRUD have not yet passed end-to-end tests. The installed Neon JavaScript SDK is a beta release, so this integration needs stability review before launch.

The current webhook route and reminder worker still reference the former Supabase design. They are not connected to the Neon database and are not deployed. Background scheduling, automated Cloud API sending, Meta Embedded Signup, billing handoff, account deletion, live delivery webhooks, deployment, and production monitoring are incomplete. Cloud API sends are not enabled. Never represent a browser-local reminder as server-scheduled or a click-to-chat link opening as a sent message.

## Local development

Use Node.js 22 or newer.

```sh
npm ci
cp .env.example .env.local
npm run dev
```

Open `http://localhost:3000`. To use the configured Neon project, provide the public Neon Auth and Data API URLs listed in `.env.example`. Those URLs identify public service endpoints; database passwords, Meta secrets, and encryption keys must remain server-side and must never use a `NEXT_PUBLIC_` prefix. Do not use preview mode for customer data.

## Database migrations

The versioned migrations live in `neon/migrations/`. Apply them in ascending order to the Neon `neondb` database using the Neon SQL editor or a properly protected migration runner. Review and back up before applying changes to a non-development database. The currently applied migrations are `202610120001` through `202610120005`; the source migration history is the deployment record. `0004` handles missing JWT claims for system-triggered audit events; `0005` avoids audit inserts when contact rows are deleted as part of business deletion.

## Authentication and tenant security

Neon Auth is provisioned with email/password support, and Neon Data API access is intended to use PostgreSQL grants and RLS. Tenant identity comes from the verified JWT `sub` claim via `private.current_user_id()`. `ensure_business()` creates a business for the authenticated user and seeds editable draft templates. Live tenant isolation was checked with synthetic JWT claims at the PostgreSQL role level. Browser signup, verification email delivery, password recovery, membership roles, business deletion, and browser-to-database RLS workflows still require end-to-end validation before public use.

## Scheduling and WhatsApp

The browser is not a scheduler. The old Supabase Edge Function source is retained temporarily but is not suitable for the current Neon deployment. No durable worker or schedule is active. Do not rely on reminders executing when the browser is closed until a Neon-compatible durable queue/worker, retry and recovery behavior, and a closed-browser deployment test are implemented.

Manual mode creates a WhatsApp click-to-chat link with prefilled text and requires the user to press Send. Automated messaging must use Meta's official Cloud API, approved templates when required, consent and opt-out checks, customer-owned credentials and billing, signature-verified webhooks, idempotency, and delivery status reconciliation. None of the live sending/onboarding path is configured. Do not enable chargeable sends until Meta eligibility and customer billing are verified.

## Environment variables

| Variable | Purpose | Current handling |
| --- | --- | --- |
| `NEXT_PUBLIC_NEON_AUTH_URL` | Public Neon Auth endpoint | Set in `.env.example` |
| `NEXT_PUBLIC_NEON_DATA_API_URL` | Public Neon Data API endpoint | Set in `.env.example` |
| `NEON_DATABASE_URL` | Server-only PostgreSQL connection string for migrations/worker | Empty; do not commit a real value |
| `NEON_AUTH_COOKIE_SECRET` | Secret for future server-side auth integration | Empty; not currently used |
| `TOKEN_ENCRYPTION_KEY` | Server-only AES-GCM key for customer WhatsApp tokens | Empty; token onboarding is not implemented |
| `META_APP_ID`, `META_APP_SECRET`, `META_CONFIG_ID` | Meta app and Embedded Signup configuration | Not configured |
| `META_WEBHOOK_VERIFY_TOKEN` | Meta webhook challenge verification | Not configured |
| `REMINDER_WORKER_SECRET` | Private worker authorization | Not configured |
| `PUBLIC_APP_URL` | Canonical redirect and webhook origin | Local default only |

Put real values in ignored `.env.local` or encrypted hosting settings only. Never put database credentials or provider secrets in browser code, Git, screenshots, or logs.

## Verification

Run:

```sh
npm test
npm run lint
npm run build
```

At the 2026-10-12 local checkpoint, `npm test` passed 27/27 tests, `npm run lint` passed, and `npm run build` exited successfully, including the app and legacy Edge Function TypeScript checks. Workspace inserts now retain database-returned IDs for contacts, reminders and templates, and CSV imports persist their generated contact IDs. Updates must return a tenant-filtered saved row before the UI reports success. Executable mocked regression tests cover contact-to-reminder identity, tenant-scoped updates and rejected writes. Existing tests cover utilities, consent, timezone/DST behavior, templating, mocked Meta payloads, webhook signature parsing, retry rules, and source-level worker/migration properties. They do not establish working authentication, deployed background execution, live Meta sending, or full browser workflows. Dependency security audit has not been verified because registry access was unavailable in the prior run; rerun `npm audit --omit=dev --audit-level=high` before release.

## Deployment and costs

The database is on the user's Neon Free project. Neon service quotas and limits can change; verify the current Neon plan and usage in the console before public launch. No paid infrastructure or Meta messaging was activated as part of this work. There is no Vercel deployment yet. Vercel Hobby is limited to personal, non-commercial use; use a commercially permitted host and plan for public commercial SaaS. Do not activate a paid plan without explicit approval.

GitHub source repository: <https://github.com/smtalhadv-web/whatsapp-reminder-pro>

## Roadmap

1. Finish and test Neon authentication, business onboarding, tenant-backed CRUD, and password recovery.
2. Migrate the webhook and implement a durable Neon-compatible reminder worker with idempotency, retries, cancellation, and recovery.
3. Complete privacy workflows, rate limits, audit/security review, and responsive browser end-to-end tests.
4. Implement official Meta Embedded Signup and customer billing handoff only after eligibility and billing are verified.
5. Deploy to a commercially compliant host, test the live scheduled path with the browser closed, and document rollback and monitoring.
6. After Reminder Pro meets its release gates, reuse the shared business, contact, consent, templates, messaging, scheduling, and audit foundations for Invoice & Receipt, Mini CRM, Order Manager, Form Builder, Booking Manager, and AI Receptionist.
