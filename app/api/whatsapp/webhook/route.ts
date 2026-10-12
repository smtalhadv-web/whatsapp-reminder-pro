import { NextRequest, NextResponse } from 'next/server';
import { parseMetaStatusUpdates, toStoredMessageStatus, verifyMetaSignature } from '@/lib/meta-webhook';
import { withWorkerDatabase } from '@/lib/worker-database';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(req: NextRequest) {
  const verifyToken = process.env.META_WEBHOOK_VERIFY_TOKEN;
  const params = req.nextUrl.searchParams;
  if (params.get('hub.mode') === 'subscribe' && verifyToken &&
      params.get('hub.verify_token') === verifyToken) {
    return new NextResponse(params.get('hub.challenge') || '', {
      status: 200, headers: { 'content-type': 'text/plain' },
    });
  }
  return NextResponse.json({ error: 'Webhook verification failed' }, { status: 403 });
}

export async function POST(req: NextRequest) {
  const secret = process.env.META_APP_SECRET;
  if (!secret || !process.env.NEON_DATABASE_URL) {
    return NextResponse.json({ error: 'Webhook processing is not configured' }, { status: 503 });
  }
  const raw = await req.text();
  if (!verifyMetaSignature(raw, req.headers.get('x-hub-signature-256'), secret)) {
    return NextResponse.json({ error: 'Invalid signature' }, { status: 401 });
  }
  let payload: unknown;
  try {
    payload = JSON.parse(raw);
  } catch {
    return NextResponse.json({ error: 'Invalid JSON' }, { status: 400 });
  }
  const statuses = parseMetaStatusUpdates(payload);
  try {
    await withWorkerDatabase(async db => {
      for (const status of statuses) {
        await db.query(
          'SELECT public.record_meta_delivery_status($1, $2, $3, $4)',
          [status.id, toStoredMessageStatus(status.status), status.timestamp ?? 0,
            status.status === 'failed' ? status.errorCode ?? 'provider_error' : null],
        );
      }
    });
  } catch {
    return NextResponse.json({ error: 'Delivery status could not be stored' }, { status: 503 });
  }
  return NextResponse.json({ ok: true, processed: statuses.length });
}
