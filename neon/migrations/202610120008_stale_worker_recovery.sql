-- Mark interrupted sends as uncertain, not automatically retryable.
-- This avoids duplicate WhatsApp messages if the provider accepted a request
-- but the worker crashed before persisting the response.
CREATE OR REPLACE FUNCTION public.requeue_stale_reminder_runs(
  p_timeout_minutes integer DEFAULT 15,
  p_limit integer DEFAULT 50
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE v_count integer;
BEGIN
  IF p_timeout_minutes < 5 OR p_timeout_minutes > 1440
     OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'invalid recovery limits';
  END IF;

  WITH stale AS (
    SELECT id
    FROM public.reminder_runs
    WHERE status = 'processing'
      AND locked_at < now() - make_interval(mins => p_timeout_minutes)
      AND provider_message_id IS NULL
    ORDER BY locked_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE public.reminder_runs rr
  SET status = 'delivery_unknown',
      last_error_code = 'WORKER_INTERRUPTED',
      last_error_safe = 'Worker stopped before provider acceptance could be confirmed; manual reconciliation required to avoid duplicate delivery.',
      updated_at = now()
  FROM stale
  WHERE rr.id = stale.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.requeue_stale_reminder_runs(integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.requeue_stale_reminder_runs(integer, integer) FROM authenticated;
