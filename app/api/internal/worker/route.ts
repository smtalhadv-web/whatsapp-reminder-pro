import { NextRequest, NextResponse } from 'next/server';
import { timingSafeEqual } from 'node:crypto';
import { withWorkerDatabase } from '../../../../lib/worker-database';
import { dispatchClaimedReminders } from '../../../../lib/worker-dispatch';

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
  if (!process.env.NEON_DATABASE_URL) {
    return NextResponse.json({ status: 'not_configured', dispatched: 0 }, { status: 503 });
  }
  try {
    const result = await withWorkerDatabase(async db => {
      const enqueued = await db.query<{ count: number }>(
        'SELECT public.enqueue_due_reminder_runs($1) AS count', [100],
      );
      const uncertain = await db.query<{ count: number }>(
        'SELECT public.requeue_stale_reminder_runs($1, $2) AS count', [15, 50],
      );
      return {
        queued: Number(enqueued.rows[0]?.count ?? 0),
        marked_delivery_unknown: Number(uncertain.rows[0]?.count ?? 0),
      };
    });
    const dispatch = await dispatchClaimedReminders(10);
    return NextResponse.json({
      status: dispatch.enabled ? 'dispatch_processed' : 'queue_maintained',
      ...result,
      dispatch,
      dispatched: dispatch.accepted,
    });
  } catch (error) {
    console.error('Worker queue maintenance failed', error instanceof Error ? error.name : 'UnknownError');
    return NextResponse.json({ error: 'Queue maintenance failed', dispatched: 0 }, { status: 503 });
  }
}

export async function GET() {
  return NextResponse.json({ error: 'Method not allowed' }, { status: 405 });
}
