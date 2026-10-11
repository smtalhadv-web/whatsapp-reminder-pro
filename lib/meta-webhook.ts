import { createHmac, timingSafeEqual } from 'node:crypto';

export type MetaDeliveryStatus = 'sent' | 'delivered' | 'read' | 'failed';
export type MetaStatusUpdate = { id: string; status: MetaDeliveryStatus; errorCode?: string; timestamp?: number };
type JsonObject = Record<string, unknown>;
const isObject = (value: unknown): value is JsonObject => typeof value === 'object' && value !== null && !Array.isArray(value);
const asArray = (value: unknown): unknown[] => Array.isArray(value) ? value : [];

export function verifyMetaSignature(rawBody: string, signature: string | null, appSecret: string): boolean {
  if (!signature || !/^sha256=[a-f0-9]{64}$/i.test(signature)) return false;
  const expected = `sha256=${createHmac('sha256', appSecret).update(rawBody).digest('hex')}`;
  const expectedBytes = Buffer.from(expected, 'utf8');
  const suppliedBytes = Buffer.from(signature, 'utf8');
  return expectedBytes.length === suppliedBytes.length && timingSafeEqual(expectedBytes, suppliedBytes);
}

export function parseMetaStatusUpdates(payload: unknown): MetaStatusUpdate[] {
  if (!isObject(payload)) return [];
  const updates: MetaStatusUpdate[] = [];
  for (const entry of asArray(payload.entry)) {
    if (!isObject(entry)) continue;
    for (const change of asArray(entry.changes)) {
      if (!isObject(change) || !isObject(change.value)) continue;
      for (const status of asArray(change.value.statuses)) {
        if (!isObject(status) || typeof status.id !== 'string' || !status.id) continue;
        if (!['sent', 'delivered', 'read', 'failed'].includes(String(status.status))) continue;
        const update: MetaStatusUpdate = { id: status.id, status: status.status as MetaDeliveryStatus };
        const timestamp = typeof status.timestamp === 'string' || typeof status.timestamp === 'number' ? Number(status.timestamp) : NaN;
        if (Number.isSafeInteger(timestamp) && timestamp > 0) update.timestamp = timestamp;
        if (update.status === 'failed') {
          const error = asArray(status.errors).find(isObject);
          if (error && (typeof error.code === 'number' || typeof error.code === 'string')) {
            update.errorCode = String(error.code).slice(0, 64);
          }
        }
        updates.push(update);
      }
    }
  }
  return updates;
}

export function toStoredMessageStatus(status: MetaDeliveryStatus): 'accepted' | 'delivered' | 'read' | 'failed' {
  if (status === 'sent') return 'accepted';
  return status;
}
