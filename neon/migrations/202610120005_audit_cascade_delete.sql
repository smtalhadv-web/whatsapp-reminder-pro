-- Do not create a child audit record while its business is being deleted by
-- cascade. Direct contact deletes remain audited while the business exists.
create or replace function public.audit_contact_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  row_business_id uuid;
  row_id uuid;
  action_name text;
  row_consent boolean;
  row_opted_out boolean;
begin
  if tg_op = 'DELETE' and not exists (
    select 1 from public.businesses where id = old.business_id
  ) then
    return old;
  end if;
  if pg_trigger_depth() > 1 then
    if tg_op = 'DELETE' then return old; else return new; end if;
  end if;
  if tg_op = 'DELETE' then
    row_business_id := old.business_id;
    row_id := old.id;
    action_name := 'contact.deleted';
    row_consent := old.consent;
    row_opted_out := old.opted_out;
  else
    row_business_id := new.business_id;
    row_id := new.id;
    row_consent := new.consent;
    row_opted_out := new.opted_out;
    if tg_op = 'INSERT' then
      action_name := 'contact.created';
    elsif old.consent is distinct from new.consent
      or old.consent_source is distinct from new.consent_source
      or old.consent_recorded_at is distinct from new.consent_recorded_at
      or old.opted_out is distinct from new.opted_out then
      action_name := 'contact.consent_updated';
    else
      action_name := 'contact.updated';
    end if;
  end if;
  insert into public.audit_logs(business_id, actor_user_id, action, object_type, object_id, safe_details)
    values(row_business_id, private.current_user_id(), action_name, 'contact', row_id::text,
      jsonb_build_object('consent', row_consent, 'opted_out', row_opted_out));
  if tg_op = 'DELETE' then return old; else return new; end if;
end
$$;
