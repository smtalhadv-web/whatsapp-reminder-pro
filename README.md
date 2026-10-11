# WhatsApp Reminder Pro

Mobile-first reminder dashboard and first module in WhatsApp Business Toolkit.

## Current state

This repository contains a functional local preview: contacts, opt-out/consent fields, CSV import/export, workspace export, editable and deletable tenant-owned starter templates, reminder CRUD, pause/resume/cancel, recurrence selection, click-to-chat manual sending, honest message history, analytics from recorded records, dark mode, and mobile navigation. Without Supabase environment variables, it uses browser-local preview data and a visible warning. Do not use demo mode for real customer information.

Supabase Auth and tenant-backed CRUD are wired for a connected Supabase project. The SQL migration defines tenant tables, role memberships, RLS, encrypted-token columns, audit and message histories, unique reminder occurrence keys, and a durable scheduler queue. A private Edge Function dispatcher now claims work atomically, rechecks cancellation and consent, requires approved templates and a single active customer connection, decrypts customer-owned credentials, and calls the official Cloud API. Token encryption/decryption, bounded 429 retry handling, an ambiguous-delivery state, and early/out-of-order webhook status handling are covered by tests. The function and database migration have not been deployed or verified against a live Supabase project.

Automated Cloud API sending remains disabled in the UI and the worker exits unless its private `WRP_ENABLE_CLOUD_SEND` secret is explicitly set to `true`. Do not enable it until a customer-owned Meta account, direct customer billing, Tech Provider/Embedded Signup approval, token onboarding, and a deployed worker are configured and verified. Meta may charge customers; this app does not charge a subscription or collect card details. Manual mode opens WhatsApp with a prefilled text and requires the user to send it; an opened link is never marked delivered.

## Local run

1. Install the pinned dependencies with Node.js 22+.
2. Copy `.env.example` to `.env.local` and provide Supabase project URL and publishable key only after creating the project.
3. Apply the migration in `supabase/migrations` using the Supabase SQL editor or CLI after reviewing it.
4. Set Auth email verification and the production redirect URLs in Supabase Auth.
5. Run `npm run dev` and open `http://localhost:3000`.

Without step 2, the app starts in local preview mode.

## Scheduling design

Vercel Hobby cron is not suitable for timely recurring reminders: its free-tier cron schedule is limited to daily. Supabase `pg_cron` can enqueue due reminders at minute intervals, and `claim_reminder_runs` uses row locks plus unique occurrence keys. The Edge Function retries explicit HTTP 429 rejections with bounded backoff. It does not retry network timeouts or ambiguous provider outcomes, which move to `delivery_unknown` to avoid duplicate sends. The enqueue/dispatch/reconciliation cron jobs are deliberately not activated; live recovery and scheduling have not been verified.

## Deployments

Vercel configuration is compatible with a Next.js deployment, but this app is intended for commercial SaaS use. Vercel Hobby is restricted to personal, non-commercial use; use a commercially permitted host/plan before a public commercial deployment. No deployment has been created. Add no secrets to Git. Configure environment values in the selected hosting dashboard.

Source repository: https://github.com/smtalhadv-web/whatsapp-reminder-pro

## Known release gates

- The GitHub repository exists and is public. No deployment exists yet.
- No Supabase project exists for Reminder Pro. The available organization is an account-level target; project creation requires explicit organization selection and cost confirmation under the connected setup flow.
- Meta Embedded Signup requires the operator's Meta app and Tech Provider eligibility and has not been connected.
- Direct customer billing arrangements must be verified before enabling Cloud API sends.
- The Edge Function and queue claims are source code only: deployment, cron configuration, live retry/recovery checks, and operator monitoring remain release gates. Webhook credentials and end-to-end callback verification, Meta onboarding and token storage, account deletion, and production legal/retention policies also remain gates. Workspace export is implemented; account deletion is not. The webhook route verifies signatures and stores status updates but has not been configured or tested against Meta.
- Local recurring reminders are stored and displayed; browser-local preview does not run reminders after the browser is closed.

## Local verification

Run `npm ci`, `npm test`, `npm run lint`, and `npm run build`. The build checks the Next.js app and separately type-checks the Edge Function using its Deno runtime declarations before creating the production bundle. Automated tests cover utility and timezone behavior, consent, template interpolation, mocked Cloud API payload creation, AES-GCM token encryption, retry policy, webhook signatures and race handling, audit structure, and migration structure. They do not replace database integration, auth, browser E2E, or live delivery tests. GitHub Actions is configured to run the same quality gates on pushes and pull requests.

## Environment variables

- `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`: public project URL and publishable key for the browser client.
- `SUPABASE_SERVICE_ROLE_KEY`: server-only key for verified Meta webhook updates; never use a `NEXT_PUBLIC_` prefix.
- `TOKEN_ENCRYPTION_KEY`: server-only base64-encoded 32-byte AES-GCM key used by the token encryption helpers and worker. Store it only in Edge Function secrets; no OAuth onboarding route currently writes encrypted tokens.
- `META_APP_ID`, `META_APP_SECRET`, `META_CONFIG_ID`, and `META_WEBHOOK_VERIFY_TOKEN`: Meta app/webhook configuration. These are not configured in this source tree.
- Edge Function secrets: `REMINDER_WORKER_SECRET` (random bearer secret), `TOKEN_ENCRYPTION_KEY`, `META_GRAPH_API_VERSION`, and `WRP_ENABLE_CLOUD_SEND=false`. The Edge Function uses the Supabase-injected secret key. Keep the send flag false until external Meta and billing gates are met.
- `PUBLIC_APP_URL`: canonical application URL for provider redirects once onboarding is implemented.

Keep real values in local ignored `.env.local` and the hosting provider's encrypted environment settings. Never commit them.

## Toolkit roadmap

After Reminder Pro meets its release gates, the shared tenant, contact, consent, templates, messaging and audit foundations are intended to support WhatsApp Invoice & Receipt, Mini CRM, Order Manager, Form Builder, Booking Manager, and AI Receptionist modules. Those products are not implemented here.

## Security check status

`npm audit --omit=dev --audit-level=high` was attempted but could not reach `registry.npmjs.org` in the restricted workspace (`connect EPERM`). Dependency advisories therefore remain unverified; rerun the command in an environment with registry access before release. The in-repo check does not establish that no high-severity dependency vulnerabilities exist.
