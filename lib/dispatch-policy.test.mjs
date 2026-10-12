import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import ts from 'typescript';

const source = readFileSync(new URL('./dispatch-policy.ts', import.meta.url), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
const exports = {};
new Function('exports', js)(exports);
const { evaluateDispatch, retryDelaySeconds } = exports;
const now = new Date('2026-10-12T12:00:00Z');
const reminder = { mode: 'automatic', status: 'scheduled', due_at: '2026-10-12T11:00:00Z' };
const contact = { consent: true, opted_out: false, consent_recorded_at: '2026-10-01T00:00:00Z' };

test('eligible only when due and consented', () => {
  assert.deepEqual(evaluateDispatch(reminder, contact, now), { eligible: true });
});
for (const [label, patch, reason] of [
  ['manual', { mode: 'manual' }, 'not_automatic'],
  ['paused', { status: 'paused' }, 'not_scheduled'],
  ['future', { due_at: '2026-10-13T00:00:00Z' }, 'not_due'],
  ['invalid due date', { due_at: 'not-a-date' }, 'invalid_due_date'],
]) test(label, () => assert.equal(evaluateDispatch({ ...reminder, ...patch }, contact, now).reason, reason));

test('rejects absent, unconsented and opted-out contacts', () => {
  assert.equal(evaluateDispatch(reminder, null, now).reason, 'no_consent');
  assert.equal(evaluateDispatch(reminder, { ...contact, consent: false }, now).reason, 'no_consent');
  assert.equal(evaluateDispatch(reminder, { ...contact, consent_recorded_at: null }, now).reason, 'no_consent');
  assert.equal(evaluateDispatch(reminder, { ...contact, opted_out: true }, now).reason, 'opted_out');
});
test('retry delay grows and caps at one hour', () => {
  assert.deepEqual([1, 2, 3, 8].map(retryDelaySeconds), [30, 60, 120, 3600]);
  assert.throws(() => retryDelaySeconds(0));
});
