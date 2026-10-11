export type WorkerTemplate = { body: string; name: string; language: string };

export function templateVariableNames(body: string): string[] {
  return [...body.matchAll(/\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/g)].map((match) => match[1]);
}

export function templateParameters(body: string, values: Record<string, string>): string[] {
  const names = templateVariableNames(body);
  const missing = [...new Set(names.filter((name) => typeof values[name] !== 'string' || !values[name].trim()))];
  if (missing.length) throw new Error(`Missing template values: ${missing.join(', ')}`);
  return names.map((name) => values[name]);
}

// Retry only provider responses that explicitly reject the request as rate limited.
// Network errors and other responses can be ambiguous: the provider may have accepted
// a message before the connection failed, so automatic retry could create a duplicate.
export function retryDelayMs(attempt: number, random = 0.5): number {
  const boundedAttempt = Math.min(Math.max(attempt, 1), 11);
  const base = Math.min(6 * 60 * 60 * 1000, 30_000 * 2 ** (boundedAttempt - 1));
  return Math.round(base * (0.8 + Math.max(0, Math.min(1, random)) * 0.4));
}

export function shouldRetryProviderResponse(status: number, attempt: number, maxAttempts = 5): boolean {
  return status === 429 && attempt < maxAttempts;
}

export async function requestMetaTemplate(input: {
  apiVersion: string;
  phoneNumberId: string;
  accessToken: string;
  recipient: string;
  templateName: string;
  language: string;
  parameters: string[];
}, fetcher: typeof fetch = fetch): Promise<Response> {
  const payload = {
    messaging_product: 'whatsapp',
    to: input.recipient.replace(/\D/g, ''),
    type: 'template',
    template: {
      name: input.templateName,
      language: { code: input.language },
      ...(input.parameters.length ? { components: [{ type: 'body', parameters: input.parameters.map((text) => ({ type: 'text', text })) }] } : {}),
    },
  };
  return fetcher(`https://graph.facebook.com/${input.apiVersion}/${input.phoneNumberId}/messages`, {
    method: 'POST',
    headers: { authorization: `Bearer ${input.accessToken}`, 'content-type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(15_000),
  });
}

export function decodeBytea(value: unknown): Uint8Array {
  if (value instanceof Uint8Array) return value;
  if (typeof value !== 'string') throw new Error('Invalid encrypted token data');
  const hex = value.startsWith('\\x') ? value.slice(2) : value;
  if (!/^(?:[0-9a-f]{2})*$/i.test(hex)) throw new Error('Invalid encrypted token data');
  return Uint8Array.from(hex.match(/.{2}/g) || [], (byte) => parseInt(byte, 16));
}

function toPgBytea(bytes: Uint8Array): string {
  return `\\x${[...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('')}`;
}

function decodeKey(keyText: string): Uint8Array {
  const bytes = Uint8Array.from(atob(keyText), (char) => char.charCodeAt(0));
  if (bytes.length !== 32) throw new Error('TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte key');
  return bytes;
}

export async function encryptAccessToken(token: string, keyText: string): Promise<{ ciphertext: string; iv: string }> {
  const keyBytes = decodeKey(keyText);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await crypto.subtle.importKey('raw', keyBytes.buffer as ArrayBuffer, 'AES-GCM', false, ['encrypt']);
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv.buffer as ArrayBuffer }, key, new TextEncoder().encode(token).buffer as ArrayBuffer));
  return { ciphertext: toPgBytea(ciphertext), iv: toPgBytea(iv) };
}

export async function decryptAccessToken(ciphertext: unknown, iv: unknown, keyText: string): Promise<string> {
  const keyBytes = decodeKey(keyText);
  const ivBytes = decodeBytea(iv);
  const encryptedBytes = decodeBytea(ciphertext);
  const key = await crypto.subtle.importKey('raw', keyBytes.buffer as ArrayBuffer, 'AES-GCM', false, ['decrypt']);
  const plaintext = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: ivBytes.buffer as ArrayBuffer }, key, encryptedBytes.buffer as ArrayBuffer);
  return new TextDecoder().decode(plaintext);
}
