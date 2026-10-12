/**
 * Pure scheduling guards for the Neon-backed reminder dispatcher.
 * These helpers never send messages or mutate records.
 * The worker must re-check consent and claim a run transactionally before sending.
 */
export type DispatchContact = {
  consent: boolean;
  opted_out: boolean;
  consent_recorded_at: string | null;
};
export type DispatchReminder = {
  status: string;
  mode: string;
  due_at: string;
};
export type DispatchDecision =
  | { eligible: true }
  | { eligible: false; reason: 'not_automatic' | 'not_scheduled' | 'not_due' | 'no_consent' | 'opted_out' | 'invalid_due_date' };

export function evaluateDispatch(
  reminder: DispatchReminder,
  contact: DispatchContact | null,
  now: Date = new Date(),
): DispatchDecision {
  if (reminder.mode !== 'automatic') return { eligible: false, reason: 'not_automatic' };
  if (reminder.status !== 'scheduled') return { eligible: false, reason: 'not_scheduled' };
  const due = Date.parse(reminder.due_at);
  if (!Number.isFinite(due)) return { eligible: false, reason: 'invalid_due_date' };
  if (due > now.getTime()) return { eligible: false, reason: 'not_due' };
  if (!contact?.consent || !contact.consent_recorded_at) return { eligible: false, reason: 'no_consent' };
  if (contact.opted_out) return { eligible: false, reason: 'opted_out' };
  return { eligible: true };
}

/** Exponential retry delay with a maximum of one hour; no jitter is applied here. */
export function retryDelaySeconds(attempt: number): number {
  if (!Number.isInteger(attempt) || attempt < 1) throw new Error('attempt must be a positive integer');
  return Math.min(3600, 30 * 2 ** Math.min(attempt - 1, 20));
}
