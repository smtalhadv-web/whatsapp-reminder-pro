import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@supabase/supabase-js';
import { parseMetaStatusUpdates, toStoredMessageStatus, verifyMetaSignature } from '@/lib/meta-webhook';
export const runtime = 'nodejs';
export async function GET(req: NextRequest) {
  const verifyToken = process.env.META_WEBHOOK_VERIFY_TOKEN;
  const params = req.nextUrl.searchParams;
  if (params.get('hub.mode') === 'subscribe' && verifyToken && params.get('hub.verify_token') === verifyToken) {
    return new NextResponse(params.get('hub.challenge') || '', { status: 200, headers: { 'content-type': 'text/plain' } });
  }
  return NextResponse.json({ error: 'Webhook verification failed' }, { status: 403 });
}
export async function POST(req: NextRequest) {
  const secret = process.env.META_APP_SECRET;
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!secret || !url || !serviceKey) return NextResponse.json({ error: 'Webhook processing is not configured' }, { status: 503 });
  const raw = await req.text();
  if (!verifyMetaSignature(raw, req.headers.get('x-hub-signature-256'), secret)) return NextResponse.json({ error: 'Invalid signature' }, { status: 401 });
  let payload: any;
  try { payload = JSON.parse(raw); } catch { return NextResponse.json({ error: 'Invalid JSON' }, { status: 400 }); }
  const supabase = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const statuses = parseMetaStatusUpdates(payload);
  for (const status of statuses) {
    const safeStatus = toStoredMessageStatus(status.status);
    const { error } = await supabase.from('provider_status_events').upsert({
      provider_message_id: status.id,
      status: safeStatus,
      provider_timestamp: status.timestamp || 0,
      error_code: status.status === 'failed' ? status.errorCode || 'provider_error' : null,
    }, { onConflict: 'provider_message_id,status,provider_timestamp', ignoreDuplicates: true });
    if (error) return NextResponse.json({ error: 'Delivery status could not be stored' }, { status: 500 });
  }
  return NextResponse.json({ ok: true, processed: statuses.length });
}
