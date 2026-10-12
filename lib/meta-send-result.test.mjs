import test from 'node:test';
import assert from 'node:assert/strict';
import { classifyMetaSendResponse, classifyMetaNetworkFailure } from './meta-send-result.ts';

test('records accepted Meta message IDs', () => {
  assert.deepEqual(classifyMetaSendResponse(200, { messages: [{ id: 'wamid.123' }] }, 1),
    { outcome: 'accepted', providerMessageId: 'wamid.123' });
});
test('success without provider ID is not retryable', () => {
  assert.equal(classifyMetaSendResponse(200, {}, 1).outcome, 'delivery_unknown');
});
test('rate limiting retries only while attempts remain', () => {
  assert.equal(classifyMetaSendResponse(429, {}, 2).outcome, 'retry_wait');
  assert.equal(classifyMetaSendResponse(429, {}, 5).outcome, 'failed');
});
test('network ambiguity is never automatically retried', () => {
  assert.equal(classifyMetaNetworkFailure().outcome, 'delivery_unknown');
});
test('other rejected responses are terminal', () => {
  assert.deepEqual(classifyMetaSendResponse(400, {}, 1),
    { outcome: 'failed', errorCode: 'META_HTTP_400' });
});
