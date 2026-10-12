-- Persist signed Meta delivery status callbacks and reconcile message state.
CREATE OR REPLACE FUNCTION public.record_meta_delivery_status(
  p_message_id text, p_status text, p_timestamp bigint, p_error_code text DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql SECURITY INVOKER SET search_path=public,pg_temp AS $$
BEGIN
  IF p_message_id IS NULL OR length(p_message_id)>512
     OR p_status NOT IN ('accepted','delivered','read','failed')
     OR p_timestamp IS NULL OR p_timestamp<0 THEN
    RAISE EXCEPTION 'invalid provider event';
  END IF;
  INSERT INTO public.provider_status_events(provider_message_id,status,provider_timestamp,error_code)
  VALUES(p_message_id,p_status,p_timestamp,left(p_error_code,80))
  ON CONFLICT(provider_message_id,status,provider_timestamp) DO NOTHING;
  UPDATE public.reminder_runs
  SET status=CASE WHEN p_status IN ('read','delivered') THEN 'delivered'
    WHEN p_status='failed' THEN 'failed' ELSE status END, updated_at=now()
  WHERE provider_message_id=p_message_id AND
    ((p_status IN ('delivered','read') AND status IN ('accepted','delivered'))
     OR (p_status='failed' AND status='accepted'));
  UPDATE public.message_logs
  SET status=CASE WHEN p_status='accepted' THEN status ELSE p_status END,
      failure_code=CASE WHEN p_status='failed' THEN left(p_error_code,80) ELSE failure_code END
  WHERE provider_message_id=p_message_id AND
    ((p_status='read' AND status IN ('accepted','sent','delivered','read'))
     OR (p_status='delivered' AND status IN ('accepted','sent','delivered'))
     OR (p_status='failed' AND status IN ('accepted','sent')));
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.record_meta_delivery_status(text,text,bigint,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_meta_delivery_status(text,text,bigint,text) FROM authenticated;
