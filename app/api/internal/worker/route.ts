import { NextRequest, NextResponse } from 'next/server';
import { timingSafeEqual } from 'node:crypto';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

function authorized(request: NextRequest): boolean {
  const secret = process.env.REMINDER_WORKER_SECRET;
  const supplied = request.headers.get('authorization');
  if (!secret || !supplied?.startsWith('Bearer ')) return false;
  const expected = Buffer.from(secret);
  const actual = Buffer.from(supplied.slice(7));
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/**
 * Reserved for the server-side dispatcher. This endpoint intentionally
 * fails closed until a privileged Neon connection, transactional job
 * lifecycle and WhatsApp provider are configured and verified.
 * Never expose the Neon database owner credentials to the browser.
 */
export async function POST(request: NextRequest) {
  if (!authorized(request)) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  return NextResponse.json(
    {
      status: 'not_configured',
      message: 'Automatic dispatch is disabled until the worker and WhatsApp provider are configured.',
      dispatched: 0,
    },
    { status: 503 },
  );
}

export async function GET() {
  return NextResponse.json({ error: 'Method not allowed' }, { status: 405 });
}
