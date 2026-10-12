import { evaluateDispatch, type DispatchContact, type DispatchReminder } from './dispatch-policy.ts';

export type DispatchCandidate = {
  id: string;
  business_id: string;
  contact_id: string | null;
  reminder: DispatchReminder;
  contact: DispatchContact | null;
};

export type DispatchPlan = {
  eligible: DispatchCandidate[];
  skipped: { id: string; reason: string }[];
};

/**
 * Read-only preflight for a database-claimed batch.
 * A real worker MUST atomically claim runs, enforce unique idempotency keys,
 * and recheck consent in the same tenant before sending.
 */
export function planDispatchBatch(
  candidates: DispatchCandidate[],
  now: Date = new Date(),
): DispatchPlan {
  const eligible: DispatchCandidate[] = [];
  const skipped: DispatchPlan['skipped'] = [];
  const seen = new Set<string>();
  for (const candidate of candidates) {
    if (!candidate.id || !candidate.business_id) {
      skipped.push({ id: candidate.id, reason: 'missing_identity' });
      continue;
    }
    const key = candidate.business_id + ':' + candidate.id;
    if (seen.has(key)) {
      skipped.push({ id: candidate.id, reason: 'duplicate_candidate' });
      continue;
    }
    seen.add(key);
    if (!candidate.contact_id || !candidate.contact) {
      skipped.push({ id: candidate.id, reason: 'missing_contact' });
      continue;
    }
    const decision = evaluateDispatch(candidate.reminder, candidate.contact, now);
    if (!decision.eligible) {
      skipped.push({ id: candidate.id, reason: decision.reason });
      continue;
    }
    eligible.push(candidate);
  }
  return { eligible, skipped };
}
