-- Complete a previously claimed run; only processing rows may transition.
-- Accepted responses require a provider message ID. Uncertain delivery must
-- not be automatically retried, avoiding duplicate customer notifications.
CREATE OR REPLACE FUNCTION public.finish_reminder_attempt(
  p_run_id uuid,
  p_outcome text,
  p_provider_message_id text DEFAULT NULL,
  p_error_code text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE v_updated integer;
BEGIN
  IF p_outcome NOT IN ('accepted', 'retry_wait', 'failed', 'delivery_unknown') THEN
    RAISE EXCEPTION 'invalid outcome';
  END IF;
  IF p_outcome = 'accepted'
     AND (p_provider_message_id IS NULL OR length(trim(p_provider_message_id)) = 0) THEN
    RAISE EXCEPTION 'accepted requires provider id';
  END IF;
  IF p_outcome = 'retry_wait' AND p_provider_message_id IS NOT NULL THEN
    RAISE EXCEPTION 'cannot retry accepted message';
  END IF;

  UPDATE public.reminder_runs
  SET status = p_outcome,
      provider_message_id = CASE WHEN p_outcome = 'accepted'
        THEN p_provider_message_id ELSE provider_message_id END,
      next_attempt_at = CASE WHEN p_outcome = 'retry_wait'
        THEN now() + make_interval(secs =>
          least(3600, 30 * power(2, least(greatest(attempt_count - 1, 0), 7))::integer))
        ELSE NULL END,
      last_error_code = left(p_error_code, 80),
      locked_at = NULL,
      updated_at = now()
  WHERE id = p_run_id AND status = 'processing';

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.finish_reminder_attempt(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finish_reminder_attempt(uuid, text, text, text) FROM authenticated;
