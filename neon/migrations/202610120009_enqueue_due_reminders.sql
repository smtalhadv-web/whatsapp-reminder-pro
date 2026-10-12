-- Materialize due automatic reminders as persistent queue rows.
-- Occurrence uniqueness prevents repeated enqueue calls from creating duplicate runs.
-- For recurring reminders, a separate recurrence advancement transaction is required.
CREATE OR REPLACE FUNCTION public.enqueue_due_reminder_runs(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE v_count integer;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 500';
  END IF;
  WITH due AS (
    SELECT r.id, r.business_id,
           COALESCE(r.next_run_at, r.due_at) AS scheduled_for
    FROM public.reminders r
    JOIN public.contacts c ON c.id = r.contact_id
      AND c.business_id = r.business_id
    WHERE r.status = 'scheduled'
      AND r.mode = 'automatic'
      AND r.cancelled_at IS NULL
      AND COALESCE(r.next_run_at, r.due_at) <= now()
      AND c.consent IS TRUE
      AND c.consent_recorded_at IS NOT NULL
      AND c.opted_out IS FALSE
    ORDER BY COALESCE(r.next_run_at, r.due_at), r.id
    LIMIT p_limit
  )
  INSERT INTO public.reminder_runs(
    business_id, reminder_id, occurrence_key, scheduled_for, status
  )
  SELECT business_id, id, scheduled_for::text, scheduled_for, 'queued'
  FROM due
  ON CONFLICT (reminder_id, occurrence_key) DO NOTHING;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_due_reminder_runs(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.enqueue_due_reminder_runs(integer) FROM authenticated;
