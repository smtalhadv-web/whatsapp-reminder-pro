import { createClient } from 'npm:@supabase/supabase-js@2.117.3';
import { decryptAccessToken, requestMetaTemplate, retryDelayMs, shouldRetryProviderResponse, templateParameters } from '../_shared/reminder-worker.ts';

const cors = { 'content-type': 'application/json; charset=utf-8' };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors });

function constantTimeEqual(left: string, right: string): boolean {
  const a = new TextEncoder().encode(left);
  const b = new TextEncoder().encode(right);
  let mismatch = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) mismatch |= (a[i] || 0) ^ (b[i] || 0);
  return mismatch === 0;
}

function formatAppointmentTime(iso: string, timezone: string): string {
  return new Intl.DateTimeFormat('en', { dateStyle: 'medium', timeStyle: 'short', timeZone: timezone }).format(new Date(iso));
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  const workerSecret = Deno.env.get('REMINDER_WORKER_SECRET');
  if (!workerSecret || !constantTimeEqual(request.headers.get('authorization') || '', `Bearer ${workerSecret}`)) return json({ error: 'Unauthorized' }, 401);
  if (Deno.env.get('WRP_ENABLE_CLOUD_SEND') !== 'true') return json({ error: 'Automated sending is disabled until Meta and customer billing are verified.' }, 503);

  const url = Deno.env.get('SUPABASE_URL');
  const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}');
  const serviceKey = keys.default || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const encryptionKey = Deno.env.get('TOKEN_ENCRYPTION_KEY');
  const graphVersion = Deno.env.get('META_GRAPH_API_VERSION');
  if (!url || !serviceKey || !encryptionKey || !graphVersion) return json({ error: 'Worker configuration is incomplete' }, 503);

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: runs, error: claimError } = await db.rpc('claim_reminder_runs', { batch_size: 5 });
  if (claimError) return json({ error: 'Could not claim scheduled work' }, 500);
  let accepted = 0;
  let failed = 0;
  let deferred = 0;

  for (const run of runs || []) {
    const reminder = run.reminder;
    const contact = run.contact;
    const template = run.template;
    const connection = run.connection;
    const failSafe = async (code: string, safeMessage: string, status = 'failed') => {
      await db.from('reminder_runs').update({ status, last_error_code: code, last_error_safe: safeMessage, locked_at: null, updated_at: new Date().toISOString() }).eq('id', run.id);
      if (reminder) await db.from('message_logs').insert({ business_id: run.business_id, reminder_id: run.reminder_id, reminder_run_id: run.id, recipient_phone: reminder.phone, mode: 'cloud', message: template?.body || '', status, failure_code: code });
      if (status === 'failed') failed++; else deferred++;
    };

    if (!contact || !contact.consent || !contact.consent_recorded_at || !contact.consent_source || contact.opted_out || contact.phone !== reminder.phone) {
      await failSafe('consent_required', 'Recipient consent is missing, invalid, or opted out.');
      continue;
    }
    if (run.connection_count !== 1 || !connection || connection.status !== 'active') {
      await failSafe('connection_unavailable', 'A single healthy customer WhatsApp connection is required.');
      continue;
    }
    if (!template?.meta_approved || !template.meta_template_name || !template.meta_language) {
      await failSafe('approved_template_required', 'An approved WhatsApp message template is required.');
      continue;
    }

    try {
      // Re-read status and consent immediately before the external request so a cancellation
      // or opt-out made while the run was queued is respected by the sender.
      const { data: currentReminder, error: reminderReadError } = await db.from('reminders').select('status,mode,contact_id,phone').eq('id', reminder.id).eq('business_id', run.business_id).maybeSingle();
      if (reminderReadError || !currentReminder) {
        await failSafe('reminder_unavailable', 'Reminder state could not be verified before sending.');
        continue;
      }
      if (!['scheduled', 'queued'].includes(currentReminder.status) || currentReminder.mode !== 'cloud') {
        await failSafe('reminder_cancelled', 'Reminder was paused or cancelled before delivery.', 'cancelled');
        continue;
      }
      const { data: currentContact, error: contactReadError } = await db.from('contacts').select('name,phone,consent,consent_recorded_at,consent_source,opted_out').eq('id', currentReminder.contact_id).eq('business_id', run.business_id).maybeSingle();
      if (contactReadError || !currentContact || !currentContact.consent || !currentContact.consent_recorded_at || !currentContact.consent_source || currentContact.opted_out || currentContact.phone !== currentReminder.phone) {
        await failSafe('consent_changed', 'Recipient consent could not be verified immediately before delivery.');
        continue;
      }
      contact.name = currentContact.name;
      contact.phone = currentContact.phone;
      const values = {
        ...(reminder.template_values || {}),
        customer_name: contact.name,
        appointment_date: formatAppointmentTime(run.scheduled_for, reminder.timezone),
        business_name: run.business?.name || '',
      } as Record<string, string>;
      const parameters = templateParameters(template.body, values);
      const token = await decryptAccessToken(connection.token_ciphertext, connection.token_iv, encryptionKey);
      const response = await requestMetaTemplate({ apiVersion: graphVersion, phoneNumberId: connection.phone_number_id, accessToken: token, recipient: contact.phone, templateName: template.meta_template_name, language: template.meta_language, parameters });
      const result = await response.json().catch(() => ({}));
      const providerMessageId = result?.messages?.[0]?.id;

      if (response.status === 429 && shouldRetryProviderResponse(response.status, run.attempt_count)) {
        const nextAttempt = new Date(Date.now() + retryDelayMs(run.attempt_count)).toISOString();
        await db.from('reminder_runs').update({ status: 'retry_wait', next_attempt_at: nextAttempt, last_error_code: 'rate_limited', last_error_safe: 'Meta rate limited this request; it will retry automatically.', locked_at: null, updated_at: new Date().toISOString() }).eq('id', run.id);
        await db.from('message_logs').insert({ business_id: run.business_id, reminder_id: run.reminder_id, reminder_run_id: run.id, recipient_phone: contact.phone, mode: 'cloud', message: template.body, status: 'retry_wait', failure_code: 'rate_limited' });
        deferred++;
        continue;
      }
      if (!response.ok) {
        const metaCode = String(result?.error?.code || `http_${response.status}`).slice(0, 60);
        const ambiguous = response.status >= 500;
        await failSafe(metaCode, ambiguous ? 'Meta returned a server error; delivery needs review before retry.' : 'Meta rejected this template message. Review the connection and template.', ambiguous ? 'delivery_unknown' : 'failed');
        continue;
      }
      if (typeof providerMessageId !== 'string' || !providerMessageId) {
        await failSafe('provider_id_missing', 'Meta accepted the request without a message ID; delivery needs review.', 'delivery_unknown');
        continue;
      }

      const { error: logError } = await db.from('message_logs').insert({ business_id: run.business_id, reminder_id: run.reminder_id, reminder_run_id: run.id, recipient_phone: contact.phone, mode: 'cloud', message: template.body, status: 'accepted', provider_message_id: providerMessageId });
      if (logError) throw new Error('Accepted message could not be recorded');
      const { error: runError } = await db.from('reminder_runs').update({ status: 'accepted', provider_message_id: providerMessageId, locked_at: null, last_error_code: null, last_error_safe: null, updated_at: new Date().toISOString() }).eq('id', run.id);
      if (runError) throw new Error('Accepted job could not be recorded');
      if (reminder.recurrence === null) await db.from('reminders').update({ status: 'sent', updated_at: new Date().toISOString() }).eq('id', reminder.id).eq('status', 'queued');
      accepted++;
    } catch {
      // A timeout or database write failure may occur after Meta accepted the send.
      // Never auto-retry this state; the stale-run reconciler and operator must review it.
      await failSafe('delivery_uncertain', 'The delivery result is uncertain; check WhatsApp Manager before retrying.', 'delivery_unknown');
    }
  }

  return json({ claimed: runs?.length || 0, accepted, failed, deferred });
});
