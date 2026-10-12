-- Harden the initial Neon schema: isolate JWT parsing, scope foreign keys to a
-- single tenant, and audit privacy-sensitive changes.

create schema if not exists private;
revoke all on schema private from public,anonymous,authenticated;
grant usage on schema private to authenticated;
create or replace function private.current_user_id()
returns text language sql stable security definer set search_path=pg_catalog as $$
  select current_setting('request.jwt.claims',true)::jsonb ->> 'sub'
$$;
revoke all on function private.current_user_id() from public,anonymous;
grant execute on function private.current_user_id() to authenticated;

create or replace function public.ensure_business(p_name text default 'My business', p_timezone text default 'Asia/Karachi')
returns uuid language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare caller_id text := private.current_user_id(); new_business_id uuid; safe_name text; safe_timezone text;
begin
  if caller_id is null or caller_id = '' then raise exception 'Authentication required'; end if;
  select business_id into new_business_id from public.business_members where user_id=caller_id limit 1;
  if new_business_id is not null then return new_business_id; end if;
  safe_name := coalesce(nullif(trim(p_name),''),'My business');
  if length(safe_name) > 160 then raise exception 'Business name is too long'; end if;
  safe_timezone := coalesce(nullif(trim(p_timezone),''),'Asia/Karachi');
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=safe_timezone) then raise exception 'Invalid timezone'; end if;
  insert into public.businesses(name,timezone) values(safe_name,safe_timezone) returning id into new_business_id;
  insert into public.business_members(business_id,user_id,role) values(new_business_id,caller_id,'owner');
  insert into public.templates(business_id,name,category,body) values
    (new_business_id,'Appointment confirmation','Appointment','Hi {{customer_name}}, your appointment with {{business_name}} is confirmed for {{appointment_date}}. We look forward to seeing you.'),
    (new_business_id,'Appointment reminder','Appointment','Hello {{customer_name}}, just a reminder about your appointment on {{appointment_date}}. Reply if you need to reschedule.'),
    (new_business_id,'Fee due','School fee','Dear {{customer_name}}, a fee of {{amount}} is due on {{appointment_date}}. Thank you, {{business_name}}.'),
    (new_business_id,'Payment reminder','Payment','Hi {{customer_name}}, this is a friendly reminder that {{amount}} is due. Contact {{business_name}} if you have already paid.'),
    (new_business_id,'Invoice notification','Invoice','Hello {{customer_name}}, invoice {{amount}} from {{business_name}} is ready. Please let us know if you have questions.'),
    (new_business_id,'Renewal reminder','Subscription renewal','Hi {{customer_name}}, your subscription with {{business_name}} renews on {{appointment_date}}. Renewal amount: {{amount}}.'),
    (new_business_id,'Follow-up','Follow-up','Hello {{customer_name}}, following up from {{business_name}}. Is there anything else we can help you with?'),
    (new_business_id,'Custom announcement','Custom reminder','Hi {{customer_name}}, a quick update from {{business_name}}: {{amount}}');
  return new_business_id;
end $$;
revoke all on function public.ensure_business(text,text) from public,anonymous;
grant execute on function public.ensure_business(text,text) to authenticated;

drop policy if exists "users read own memberships" on public.business_members;
drop policy if exists "members read business" on public.businesses;
drop policy if exists "owners edit business" on public.businesses;
drop policy if exists "members read contacts" on public.contacts;
drop policy if exists "editors manage contacts" on public.contacts;
drop policy if exists "members read templates" on public.templates;
drop policy if exists "editors manage templates" on public.templates;
drop policy if exists "members read reminders" on public.reminders;
drop policy if exists "editors manage reminders" on public.reminders;
drop policy if exists "members read message history" on public.message_logs;
drop policy if exists "editors record manual link opens" on public.message_logs;
drop policy if exists "members read reminder runs" on public.reminder_runs;
drop policy if exists "owners read audit" on public.audit_logs;

create policy "users read own memberships" on public.business_members
  for select to authenticated using(user_id=private.current_user_id());
create policy "members read business" on public.businesses
  for select to authenticated using(id in (select business_id from public.business_members where user_id=private.current_user_id()));
create policy "owners edit business" on public.businesses
  for update to authenticated
  using(id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin')))
  with check(id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin')));
create policy "members read contacts" on public.contacts for select to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id()));
create policy "editors manage contacts" on public.contacts for all to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin','member')))
  with check(business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin','member')));
create policy "members read templates" on public.templates for select to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id()));
create policy "editors manage templates" on public.templates for all to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin','member')))
  with check(business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin','member')));
create policy "members read reminders" on public.reminders for select to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id()));
create policy "editors manage reminders" on public.reminders for all to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin','member')))
  with check(business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin','member')));
create policy "members read message history" on public.message_logs for select to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id()));
create policy "editors record manual link opens" on public.message_logs for insert to authenticated
  with check(mode='manual' and status='manual_link_opened_not_sent' and business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin','member')));
create policy "members read reminder runs" on public.reminder_runs for select to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id()));
create policy "owners read audit" on public.audit_logs for select to authenticated
  using(business_id in (select business_id from public.business_members where user_id=private.current_user_id() and role in ('owner','admin')));

alter table public.templates add constraint templates_business_id_id_key unique(business_id,id);
alter table public.reminders add constraint reminders_business_id_id_key unique(business_id,id);
alter table public.reminder_runs add constraint reminder_runs_business_id_id_key unique(business_id,id);
alter table public.reminders drop constraint reminders_template_id_fkey;
alter table public.reminders add constraint reminders_business_template_fk
  foreign key(business_id,template_id) references public.templates(business_id,id) on delete set null (template_id);
alter table public.message_logs drop constraint message_logs_reminder_id_fkey;
alter table public.message_logs drop constraint message_logs_reminder_run_id_fkey;
alter table public.message_logs add constraint message_logs_business_reminder_fk
  foreign key(business_id,reminder_id) references public.reminders(business_id,id) on delete set null (reminder_id);
alter table public.message_logs add constraint message_logs_business_run_fk
  foreign key(business_id,reminder_run_id) references public.reminder_runs(business_id,id) on delete set null (reminder_run_id);

create or replace function public.audit_contact_change()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare row_business_id uuid; row_id uuid; action_name text; row_consent boolean; row_opted_out boolean;
begin
  if tg_op='DELETE' then
    row_business_id:=old.business_id; row_id:=old.id; action_name:='contact.deleted'; row_consent:=old.consent; row_opted_out:=old.opted_out;
  else
    row_business_id:=new.business_id; row_id:=new.id; row_consent:=new.consent; row_opted_out:=new.opted_out;
    if tg_op='INSERT' then action_name:='contact.created';
    elsif old.consent is distinct from new.consent or old.consent_source is distinct from new.consent_source or old.consent_recorded_at is distinct from new.consent_recorded_at or old.opted_out is distinct from new.opted_out then action_name:='contact.consent_updated';
    else action_name:='contact.updated'; end if;
  end if;
  insert into public.audit_logs(business_id,actor_user_id,action,object_type,object_id,safe_details)
    values(row_business_id,private.current_user_id(),action_name,'contact',row_id::text,jsonb_build_object('consent',row_consent,'opted_out',row_opted_out));
  if tg_op='DELETE' then return old; else return new; end if;
end $$;
revoke all on function public.audit_contact_change() from public,anonymous,authenticated;
create trigger audit_contact_change after insert or update or delete on public.contacts for each row execute function public.audit_contact_change();

create or replace function public.audit_reminder_status_change()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if old.status is distinct from new.status then
    insert into public.audit_logs(business_id,actor_user_id,action,object_type,object_id,safe_details)
      values(new.business_id,private.current_user_id(),'reminder.status_changed','reminder',new.id::text,jsonb_build_object('from',old.status,'to',new.status));
  end if;
  return new;
end $$;
revoke all on function public.audit_reminder_status_change() from public,anonymous,authenticated;
create trigger audit_reminder_status_change after update on public.reminders for each row execute function public.audit_reminder_status_change();
