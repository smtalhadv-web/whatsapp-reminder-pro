-- WhatsApp Reminder Pro: atomic claiming of existing queued reminder runs.
-- This function does not send messages or create new occurrences.
-- It must only be called by a protected server-side worker using a privileged DB role.
CREATE OR REPLACE FUNCTION public.claim_reminder_runs(p_limit integer DEFAULT 25)
RETURNS SETOF public.reminder_runs
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 100';
  END IF;

  RETURN QUERY
  WITH selected AS (
    SELECT rr.id
    FROM public.reminder_runs AS rr
    JOIN public.reminders AS r ON r.id = rr.reminder_id
      AND r.business_id = rr.business_id
    WHERE rr.status IN ('queued', 'retry_wait')
      AND (rr.next_attempt_at IS NULL OR rr.next_attempt_at <= now())
      AND rr.scheduled_for <= now()
      AND r.status = 'scheduled'
      AND r.mode = 'automatic'
      AND r.cancelled_at IS NULL
    ORDER BY COALESCE(rr.next_attempt_at, rr.scheduled_for), rr.id
    FOR UPDATE OF rr SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE public.reminder_runs AS rr
  SET status = 'processing',
      locked_at = now(),
      attempt_count = rr.attempt_count + 1,
      updated_at = now()
  FROM selected
  WHERE rr.id = selected.id
  RETURNING rr.*;
END;
$$;

-- Do not allow browser roles to invoke a worker claim function.
REVOKE ALL ON FUNCTION public.claim_reminder_runs(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_reminder_runs(integer) FROM anon;
REVOKE ALL ON FUNCTION public.claim_reminder_runs(integer) FROM authenticated;
