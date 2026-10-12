# Worker operations and production safeguards

## Implemented
- Neon queue maintenance: `enqueue_due_reminder_runs` and `requeue_stale_reminder_runs`.
- Atomic run claiming: `claim_reminder_runs` uses `FOR UPDATE SKIP LOCKED`.
- Attempt completion: `finish_reminder_attempt`.
- Signed Meta webhook persistence: `record_meta_delivery_status`.
- Protected `POST /api/internal/worker` with `Authorization: Bearer <REMINDER_WORKER_SECRET>`.
- The server uses `NEON_DATABASE_URL` exclusively, never in browser code.
- WhatsApp sending is **OFF** unless `WHATSAPP_SENDING_ENABLED=true` is explicitly set.
- The dispatcher only sends approved template messages with a connected business account.

## Not ready for general availability
- No production Meta business integration or end-to-end message send verified.
- No reliable frequent cron/scheduler configured yet. Calling the endpoint manually is not a scheduler.
- Recurring reminder advancement is not implemented.
- Webhook reconciliation and log completeness require integration testing.
- Email verification and tenant end-to-end security tests remain incomplete.

## Before enabling live sending
1. Verify verified-email signup, tenant isolation, consent and opt-out tests.
2. Connect the customer's Meta WhatsApp Business account and approved templates.
3. Set `META_APP_SECRET`, `META_WEBHOOK_VERIFY_TOKEN`, `TOKEN_ENCRYPTION_KEY`, and test encrypted token handling.
4. Configure a suitable external scheduler to call the protected endpoint and test repeated and concurrent invocations.
5. Run a real opt-in test send, confirm provider ID and signed delivered/read/failed webhooks.
6. Only then enable `WHATSAPP_SENDING_ENABLED=true` and monitor uncertain delivery records.

## Important operational caveat
The dispatcher rechecks consent before sending, but delivery races, retries, and out-of-order webhook handling still need production-level verification. Do not use with paying customers until the Definition of Done is satisfied.

## Infrastructure configured (2026-10-12)
Production Vercel now has encrypted `NEON_DATABASE_URL`, `REMINDER_WORKER_SECRET`, `TOKEN_ENCRYPTION_KEY`, and `META_WEBHOOK_VERIFY_TOKEN`. Never commit their values. Meta App Secret and customer-owned WhatsApp credentials are not connected, and `WHATSAPP_SENDING_ENABLED` remains unset (OFF). A new production deployment is needed whenever environment variables are added or changed.
