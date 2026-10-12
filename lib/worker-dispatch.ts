import { withWorkerDatabase } from './worker-database';
import { classifyMetaNetworkFailure, classifyMetaSendResponse } from './meta-send-result';
import { decryptAccessToken, requestMetaTemplate, templateParameters } from '../supabase/functions/_shared/reminder-worker';

type Job = {
  id: string;
  business_id: string;
  reminder_id: string;
  attempt_count: number;
};
type Payload = {
  phone: string;
  consent: boolean;
  opted_out: boolean;
  consent_recorded_at: string | null;
  template_body: string | null;
  template_name: string | null;
  template_language: string | null;
  meta_approved: boolean | null;
  template_values: Record<string, string> | null;
  phone_number_id: string | null;
  token_ciphertext: Uint8Array | null;
  token_iv: Uint8Array | null;
  connection_status: string | null;
};

/**
 * Deliberately opt-in: no Cloud API requests occur unless an operator
 * configures WHATSAPP_SENDING_ENABLED=true with all server-side secrets.
 */
export async function dispatchClaimedReminders(limit = 10) {
  if (process.env.WHATSAPP_SENDING_ENABLED !== 'true' ||
      !process.env.TOKEN_ENCRYPTION_KEY || !process.env.NEON_DATABASE_URL) {
    return { enabled: false, claimed: 0, accepted: 0, retrying: 0, failed: 0, uncertain: 0 };
  }
  return withWorkerDatabase(async db => {
    const jobs = (await db.query<Job>(
      'SELECT id,business_id,reminder_id,attempt_count FROM public.claim_reminder_runs($1)',
      [limit],
    )).rows;
    const totals = { enabled: true, claimed: jobs.length, accepted: 0, retrying: 0, failed: 0, uncertain: 0 };
    for (const job of jobs) {
      let outcome: 'accepted' | 'retry_wait' | 'failed' | 'delivery_unknown' = 'failed';
      let providerId: string | null = null;
      let errorCode: string | null = 'INVALID_REMINDER_CONFIGURATION';
      try {
        const result = await db.query<Payload>(`
          SELECT COALESCE(c.phone,r.phone) AS phone,
            c.consent,c.opted_out,c.consent_recorded_at,
            t.body AS template_body,t.meta_template_name AS template_name,
            t.meta_language AS template_language,t.meta_approved,
            r.template_values,
            w.phone_number_id,w.token_ciphertext,w.token_iv,
            w.status AS connection_status
          FROM public.reminders r
          JOIN public.contacts c ON c.id=r.contact_id AND c.business_id=r.business_id
          LEFT JOIN public.templates t ON t.id=r.template_id AND t.business_id=r.business_id
          LEFT JOIN LATERAL (
            SELECT phone_number_id,token_ciphertext,token_iv,status
            FROM public.whatsapp_connections
            WHERE business_id=r.business_id AND status='connected'
            ORDER BY created_at DESC LIMIT 1
          ) w ON true
          WHERE r.id=$1 AND r.business_id=$2
            AND r.status='scheduled' AND r.mode='automatic'
            AND r.cancelled_at IS NULL
          FOR UPDATE OF r,c
        `, [job.reminder_id, job.business_id]);
        const row = result.rows[0];
        if (!row || !row.consent || !row.consent_recorded_at || row.opted_out) {
          errorCode = 'CONSENT_OR_REMINDER_INVALID';
        } else if (!row.meta_approved || !row.template_name || !row.template_language ||
                   !row.template_body || !row.phone_number_id ||
                   !row.token_ciphertext || !row.token_iv || row.connection_status !== 'connected') {
          errorCode = 'META_TEMPLATE_OR_CONNECTION_MISSING';
        } else {
          const parameters = templateParameters(row.template_body, row.template_values ?? {});
          const accessToken = await decryptAccessToken(
            row.token_ciphertext, row.token_iv, process.env.TOKEN_ENCRYPTION_KEY!,
          );
          const response = await requestMetaTemplate({
            apiVersion: process.env.META_GRAPH_API_VERSION || 'v23.0',
            phoneNumberId: row.phone_number_id,
            accessToken,
            recipient: row.phone,
            templateName: row.template_name,
            language: row.template_language,
            parameters,
          });
          const body: unknown = await response.json().catch(() => null);
          const decision = classifyMetaSendResponse(response.status, body, job.attempt_count);
          outcome = decision.outcome;
          errorCode = 'errorCode' in decision ? decision.errorCode : null;
          providerId = 'providerMessageId' in decision ? decision.providerMessageId : null;
        }
      } catch {
        // A network error may occur after Meta accepts the request.
        const decision = classifyMetaNetworkFailure();
        outcome = decision.outcome;
        errorCode = decision.errorCode;
      }
      const finished = await db.query<{ updated: boolean }>(
        'SELECT public.finish_reminder_attempt($1,$2,$3,$4) AS updated',
        [job.id, outcome, providerId, errorCode],
      );
      if (!finished.rows[0]?.updated) throw new Error('Failed to finalize claimed reminder run');
      if (outcome === 'accepted') totals.accepted++;
      else if (outcome === 'retry_wait') totals.retrying++;
      else if (outcome === 'delivery_unknown') totals.uncertain++;
      else totals.failed++;
    }
    return totals;
  });
}
