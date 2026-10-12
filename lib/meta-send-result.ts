/**
 * Classifies WhatsApp Cloud API send responses conservatively.
 * A timeout or malformed successful response is delivery-unknown, never
 * automatically retried: Meta may have accepted the message already.
 */
export type SendResult =
  | { outcome: 'accepted'; providerMessageId: string }
  | { outcome: 'retry_wait'; errorCode: string }
  | { outcome: 'failed'; errorCode: string }
  | { outcome: 'delivery_unknown'; errorCode: string };

export function classifyMetaSendResponse(
  status: number,
  payload: unknown,
  attempt: number,
  maxAttempts = 5,
): SendResult {
  if (status >= 200 && status < 300) {
    const body = payload && typeof payload === 'object' ? payload as { messages?: unknown } : null;
    const messages = Array.isArray(body?.messages) ? body.messages : [];
    const first = messages[0];
    const id = first && typeof first === 'object' ? (first as { id?: unknown }).id : undefined;
    return typeof id === 'string' && id.trim()
      ? { outcome: 'accepted', providerMessageId: id }
      : { outcome: 'delivery_unknown', errorCode: 'MISSING_PROVIDER_MESSAGE_ID' };
  }
  if (status === 429 && attempt < maxAttempts) {
    return { outcome: 'retry_wait', errorCode: 'META_RATE_LIMIT' };
  }
  return { outcome: 'failed', errorCode: status === 429 ? 'META_RATE_LIMIT_EXHAUSTED' : 'META_HTTP_' + status };
}

export function classifyMetaNetworkFailure(): SendResult {
  return { outcome: 'delivery_unknown', errorCode: 'META_NETWORK_UNCERTAIN' };
}
