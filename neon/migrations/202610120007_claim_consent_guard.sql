-- Enforce contact opt-in at the moment a reminder run is claimed.
-- This is defense in depth; the sender must re-check immediately before delivery.
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
    FROM public.reminder_runs rr
    JOIN public.reminders r ON r.id = rr.reminder_id
      AND r.business_id = rr.business_id
    JOIN public.contacts c ON c.id = r.contact_id
      AND c.business_id = rr.business_id
    WHERE rr.status IN ('queued', 'retry_wait')
      AND (rr.next_attempt_at IS NULL OR rr.next_attempt_at <= now())
      AND rr.scheduled_for <= now()
      AND r.status = 'scheduled'
      AND r.mode = 'automatic'
      AND r.cancelled_at IS NULL
      AND c.consent IS TRUE
      AND c.consent_recorded_at IS NOT NULL
      AND c.opted_out IS FALSE
    ORDER BY COALESCE(rr.next_attempt_at, rr.scheduled_for), rr.id
    FOR UPDATE OF rr SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE public.reminder_runs rr
  SET status = 'processing',
      locked_at = now(),
      attempt_count = rr.attempt_count + 1,
      updated_at = now()
  FROM selected
  WHERE rr.id = selected.id
  RETURNING rr.*;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_reminder_runs(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_reminder_runs(integer) FROM authenticated;
