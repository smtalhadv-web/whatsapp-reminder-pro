import test from 'node:test';
import assert from 'node:assert/strict';
import { planDispatchBatch } from './dispatch-batch.ts';

const now = new Date('2026-10-12T12:00:00Z');
const base = {
  id: 'reminder-1',
  business_id: 'tenant-1',
  contact_id: 'contact-1',
  reminder: { mode: 'automatic', status: 'scheduled', due_at: '2026-10-12T11:00:00Z' },
  contact: { consent: true, opted_out: false, consent_recorded_at: '2026-10-01T00:00:00Z' },
};
test('only eligible reminders enter a dispatch plan', () => {
  const plan = planDispatchBatch([base], now);
  assert.equal(plan.eligible.length, 1);
  assert.equal(plan.skipped.length, 0);
});
test('duplicate candidate in same tenant is skipped', () => {
  const plan = planDispatchBatch([base, { ...base }], now);
  assert.equal(plan.eligible.length, 1);
  assert.deepEqual(plan.skipped, [{ id: base.id, reason: 'duplicate_candidate' }]);
});
test('candidate identity is scoped to tenant', () => {
  const plan = planDispatchBatch([base, { ...base, business_id: 'tenant-2' }], now);
  assert.equal(plan.eligible.length, 2);
});
test('rejects missing contact, missing identity, and opt-out', () => {
  const plan = planDispatchBatch([
    { ...base, id: '' },
    { ...base, id: 'r2', contact_id: null },
    { ...base, id: 'r3', contact: { ...base.contact, opted_out: true } },
  ], now);
  assert.deepEqual(plan.skipped.map(x => x.reason), ['missing_identity', 'missing_contact', 'opted_out']);
  assert.equal(plan.eligible.length, 0);
});
