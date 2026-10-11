-- WhatsApp Reminder Pro initial tenant schema.
-- Every tenant-owned table is RLS protected. Authorization relies on business_members,
-- never user-editable user_metadata.
create extension if not exists pgcrypto;
create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists supabase_vault with schema vault;

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 160),
  timezone text not null default 'UTC',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.business_members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','admin','member','viewer')),
  created_at timestamptz not null default now(),
  primary key (business_id,user_id)
);
create index business_members_user_idx on public.business_members(user_id);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 200),
  phone text not null check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  email text,
  tags text[] not null default '{}',
  notes text not null default '',
  consent boolean not null default false,
  consent_recorded_at timestamptz,
  consent_source text,
  opted_out boolean not null default false,
  opted_out_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,phone),
  unique (business_id,id),
  check (not opted_out or not consent)
);
create index contacts_business_name_idx on public.contacts(business_id,name);
create index contacts_business_phone_idx on public.contacts(business_id,phone);

create table public.templates (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  category text not null,
  body text not null,
  meta_template_name text,
  meta_approved boolean not null default false,
  meta_language text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.whatsapp_connections (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  waba_id text not null,
  phone_number_id text not null,
  display_phone_number text,
  business_name text,
  token_ciphertext bytea not null,
  token_iv bytea not null,
  token_key_version integer not null default 1,
  token_expires_at timestamptz,
  status text not null default 'active' check(status in ('active','revoked','error','disconnected')),
  last_health_check_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,phone_number_id)
);

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  contact_id uuid,
  title text not null check (length(trim(title)) between 1 and 240),
  category text not null default 'Custom reminder',
  phone text not null check (phone ~ '^\+[1-9][0-9]{7,14}$'),
  message text not null,
  due_at timestamptz not null,
  timezone text not null default 'UTC',
  recurrence text check (recurrence in ('daily','weekly','monthly','yearly',null)),
  recurrence_rule jsonb,
  mode text not null default 'manual' check (mode in ('manual','cloud')),
  status text not null default 'scheduled' check (status in ('scheduled','queued','paused','cancelled','sent','failed','awaiting_manual')),
  template_id uuid references public.templates(id) on delete set null,
  template_values jsonb not null default '{}',
  idempotency_key text not null default encode(gen_random_bytes(16),'hex'),
  next_run_at timestamptz,
  last_run_at timestamptz,
  cancelled_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(business_id,contact_id) references public.contacts(business_id,id) on delete set null (contact_id),
  unique (business_id,idempotency_key)
);
create index reminders_due_idx on public.reminders(status,next_run_at) where status='scheduled';
create index reminders_tenant_due_idx on public.reminders(business_id,due_at);

create table public.reminder_runs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  reminder_id uuid not null references public.reminders(id) on delete cascade,
  occurrence_key text not null,
  scheduled_for timestamptz not null,
  status text not null default 'queued' check(status in ('queued','processing','retry_wait','accepted','delivered','failed','cancelled','awaiting_manual','delivery_unknown')),
  attempt_count integer not null default 0,
  locked_at timestamptz,
  next_attempt_at timestamptz,
  last_error_code text,
  last_error_safe text,
  provider_message_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(reminder_id,occurrence_key)
);
create index reminder_runs_queue_idx on public.reminder_runs(status,next_attempt_at,created_at);

create table public.message_logs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  reminder_id uuid references public.reminders(id) on delete set null,
  reminder_run_id uuid references public.reminder_runs(id) on delete set null,
  recipient_phone text not null,
  mode text not null check(mode in ('manual','cloud')),
  message text not null,
  status text not null,
  provider_message_id text,
  failure_code text,
  created_at timestamptz not null default now(),
  unique(provider_message_id)
);
create index message_logs_tenant_created_idx on public.message_logs(business_id,created_at desc);

-- Signed Meta delivery updates can arrive before the worker commits its send response.
-- Keep unmatched provider statuses until the corresponding message row is written.
create table public.provider_status_events (
  id bigint generated always as identity primary key,
  provider_message_id text not null,
  status text not null check(status in ('accepted','delivered','read','failed')),
  provider_timestamp bigint not null default 0,
  error_code text,
  created_at timestamptz not null default now(),
  unique(provider_message_id,status,provider_timestamp)
);
create index provider_status_events_latest_idx on public.provider_status_events(provider_message_id,provider_timestamp desc);
alter table public.provider_status_events enable row level security;
revoke all on public.provider_status_events from public,anon,authenticated;
grant all on public.provider_status_events to service_role;
grant usage,select on sequence public.provider_status_events_id_seq to service_role;

create or replace function public.apply_latest_provider_status(target_provider_message_id text) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare event_row record; run_status text; matched integer;
begin
 select status,error_code into event_row from public.provider_status_events
 where provider_message_id=target_provider_message_id
 order by case status when 'read' then 5 when 'delivered' then 4 when 'failed' then 3 when 'accepted' then 2 else 1 end desc,
  provider_timestamp desc,created_at desc limit 1;
 if not found then return; end if;
 update public.message_logs set status=event_row.status,failure_code=event_row.error_code
 where provider_message_id=target_provider_message_id;
 get diagnostics matched=row_count;
 if matched=0 then return; end if;
 run_status:=case event_row.status when 'read' then 'delivered' else event_row.status end;
 update public.reminder_runs run set status=run_status,updated_at=now()
 from public.message_logs log
 where log.provider_message_id=target_provider_message_id and log.reminder_run_id=run.id and run.business_id=log.business_id;
 delete from public.provider_status_events where provider_message_id=target_provider_message_id;
end $$;
revoke all on function public.apply_latest_provider_status(text) from public,anon,authenticated;

create or replace function public.capture_provider_status_event() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 perform public.apply_latest_provider_status(new.provider_message_id);
 return new;
end $$;
revoke all on function public.capture_provider_status_event() from public,anon,authenticated;
create trigger capture_provider_status_event after insert on public.provider_status_events for each row execute function public.capture_provider_status_event();

create or replace function public.apply_pending_provider_status() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.provider_message_id is not null then perform public.apply_latest_provider_status(new.provider_message_id); end if;
 return new;
end $$;
revoke all on function public.apply_pending_provider_status() from public,anon,authenticated;
create trigger apply_pending_provider_status after insert on public.message_logs for each row execute function public.apply_pending_provider_status();

create table public.audit_logs (
  id bigint generated always as identity primary key,
  business_id uuid references public.businesses(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  object_type text,
  object_id text,
  safe_details jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end $$;
create trigger touch_businesses before update on public.businesses for each row execute function public.touch_updated_at();
create trigger touch_contacts before update on public.contacts for each row execute function public.touch_updated_at();
create trigger touch_templates before update on public.templates for each row execute function public.touch_updated_at();
create trigger touch_reminders before update on public.reminders for each row execute function public.touch_updated_at();
create trigger touch_runs before update on public.reminder_runs for each row execute function public.touch_updated_at();
create trigger touch_connections before update on public.whatsapp_connections for each row execute function public.touch_updated_at();

-- Create an owner workspace after Supabase verifies the new email. The business name is
-- only a label; permissions are assigned server-side in this trigger.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare business_id uuid;
begin
 insert into public.businesses(name) values (coalesce(nullif(trim(new.raw_user_meta_data->>'business_name'),''),'My business')) returning id into business_id;
 insert into public.business_members(business_id,user_id,role) values (business_id,new.id,'owner');
 insert into public.templates(business_id,name,category,body) values
  (business_id,'Appointment confirmation','Appointment','Hi {{customer_name}}, your appointment with {{business_name}} is confirmed for {{appointment_date}}. We look forward to seeing you.'),
  (business_id,'Appointment reminder','Appointment','Hello {{customer_name}}, just a reminder about your appointment on {{appointment_date}}. Reply if you need to reschedule.'),
  (business_id,'Fee due','School fee','Dear {{customer_name}}, a fee of {{amount}} is due on {{appointment_date}}. Thank you, {{business_name}}.'),
  (business_id,'Payment reminder','Payment','Hi {{customer_name}}, this is a friendly reminder that {{amount}} is due. Contact {{business_name}} if you have already paid.'),
  (business_id,'Invoice notification','Invoice','Hello {{customer_name}}, invoice {{amount}} from {{business_name}} is ready. Please let us know if you have questions.'),
  (business_id,'Renewal reminder','Subscription renewal','Hi {{customer_name}}, your subscription with {{business_name}} renews on {{appointment_date}}. Renewal amount: {{amount}}.'),
  (business_id,'Follow-up','Follow-up','Hello {{customer_name}}, following up from {{business_name}}. Is there anything else we can help you with?'),
  (business_id,'Custom announcement','Custom reminder','Hi {{customer_name}}, a quick update from {{business_name}}: {{amount}}');
 return new;
end $$;
revoke all on function public.handle_new_user() from public,anon,authenticated;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.is_business_member(target_business uuid) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
 select exists(select 1 from public.business_members m where m.business_id=target_business and m.user_id=auth.uid())
$$;
revoke all on function public.is_business_member(uuid) from public,anon;
grant execute on function public.is_business_member(uuid) to authenticated;

alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.contacts enable row level security;
alter table public.templates enable row level security;
alter table public.whatsapp_connections enable row level security;
alter table public.reminders enable row level security;
alter table public.reminder_runs enable row level security;
alter table public.message_logs enable row level security;
-- provider_status_events is server-only and has RLS enabled above with no client policies.
alter table public.audit_logs enable row level security;
create policy "business members can read businesses" on public.businesses for select to authenticated using(public.is_business_member(id));
create policy "owners and admins update businesses" on public.businesses for update to authenticated using(exists(select 1 from public.business_members m where m.business_id=id and m.user_id=auth.uid() and m.role in ('owner','admin'))) with check(exists(select 1 from public.business_members m where m.business_id=id and m.user_id=auth.uid() and m.role in ('owner','admin')));
create policy "members view workspace membership" on public.business_members for select to authenticated using(public.is_business_member(business_id));
create policy "members read contacts" on public.contacts for select to authenticated using(public.is_business_member(business_id));
create policy "editors manage contacts" on public.contacts for all to authenticated using(exists(select 1 from public.business_members m where m.business_id=contacts.business_id and m.user_id=auth.uid() and m.role in ('owner','admin','member'))) with check(exists(select 1 from public.business_members m where m.business_id=contacts.business_id and m.user_id=auth.uid() and m.role in ('owner','admin','member')));
create policy "members read templates" on public.templates for select to authenticated using(public.is_business_member(business_id));
create policy "editors manage templates" on public.templates for all to authenticated using(exists(select 1 from public.business_members m where m.business_id=templates.business_id and m.user_id=auth.uid() and m.role in ('owner','admin','member'))) with check(exists(select 1 from public.business_members m where m.business_id=templates.business_id and m.user_id=auth.uid() and m.role in ('owner','admin','member')));
create policy "members read reminders" on public.reminders for select to authenticated using(public.is_business_member(business_id));
create policy "editors manage reminders" on public.reminders for all to authenticated using(exists(select 1 from public.business_members m where m.business_id=reminders.business_id and m.user_id=auth.uid() and m.role in ('owner','admin','member'))) with check(exists(select 1 from public.business_members m where m.business_id=reminders.business_id and m.user_id=auth.uid() and m.role in ('owner','admin','member')));
create policy "members view runs" on public.reminder_runs for select to authenticated using(public.is_business_member(business_id));
create policy "members view history" on public.message_logs for select to authenticated using(public.is_business_member(business_id));
create policy "owners view audit" on public.audit_logs for select to authenticated using(exists(select 1 from public.business_members m where m.business_id=audit_logs.business_id and m.user_id=auth.uid() and m.role in ('owner','admin')));
-- Messaging tokens and scheduler attempts are server-only. No authenticated policies are created.

-- Record privacy-sensitive contact and reminder state changes without logging message
-- contents, phone numbers, or other personal contact data.
create or replace function public.audit_contact_change() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare row_business_id uuid; row_id uuid; action_name text; row_consent boolean; row_opted_out boolean;
begin
 if tg_op='DELETE' then
  row_business_id:=old.business_id; row_id:=old.id; action_name:='contact.deleted'; row_consent:=old.consent; row_opted_out:=old.opted_out;
 else
  row_business_id:=new.business_id; row_id:=new.id;
  row_consent:=new.consent; row_opted_out:=new.opted_out;
  if tg_op='INSERT' then action_name:='contact.created';
  elsif old.consent is distinct from new.consent or old.consent_source is distinct from new.consent_source or old.consent_recorded_at is distinct from new.consent_recorded_at or old.opted_out is distinct from new.opted_out then action_name:='contact.consent_updated';
  else action_name:='contact.updated'; end if;
 end if;
 insert into public.audit_logs(business_id,actor_user_id,action,object_type,object_id,safe_details)
 values(row_business_id,auth.uid(),action_name,'contact',row_id::text,jsonb_build_object('consent',row_consent,'opted_out',row_opted_out));
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
revoke all on function public.audit_contact_change() from public,anon,authenticated;
create trigger audit_contact_change after insert or update or delete on public.contacts for each row execute function public.audit_contact_change();

create or replace function public.audit_reminder_status_change() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if old.status is distinct from new.status then
  insert into public.audit_logs(business_id,actor_user_id,action,object_type,object_id,safe_details)
  values(new.business_id,auth.uid(),'reminder.status_changed','reminder',new.id::text,jsonb_build_object('from',old.status,'to',new.status));
 end if;
 return new;
end $$;
revoke all on function public.audit_reminder_status_change() from public,anon,authenticated;
create trigger audit_reminder_status_change after update on public.reminders for each row execute function public.audit_reminder_status_change();

-- Durable due-job creation. pg_cron wakes once per minute; reminder_runs uniqueness makes
-- retries/restarts idempotent. Configure URL and bearer token in Vault before scheduling.
create or replace function public.enqueue_due_reminders() returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare r record; occurrence text; added integer:=0;
begin
 for r in select * from public.reminders where status='scheduled' and mode='cloud' and due_at<=now() and (next_run_at is null or next_run_at<=now()) order by due_at for update skip locked limit 250 loop
  occurrence:=to_char(r.due_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"');
  insert into public.reminder_runs(business_id,reminder_id,occurrence_key,scheduled_for,status,next_attempt_at)
  values(r.business_id,r.id,occurrence,r.due_at,'queued',now()) on conflict(reminder_id,occurrence_key) do nothing;
  if found then added:=added+1; end if;
  if r.recurrence is null then
   update public.reminders set last_run_at=now(),next_run_at=null,status='queued' where id=r.id;
  else
   update public.reminders set last_run_at=now(),
    due_at=((r.due_at at time zone r.timezone) + case r.recurrence
      when 'daily' then interval '1 day' when 'weekly' then interval '1 week'
      when 'monthly' then interval '1 month' when 'yearly' then interval '1 year' end) at time zone r.timezone,
    next_run_at=((r.due_at at time zone r.timezone) + case r.recurrence
      when 'daily' then interval '1 day' when 'weekly' then interval '1 week'
      when 'monthly' then interval '1 month' when 'yearly' then interval '1 year' end) at time zone r.timezone
    where id=r.id;
  end if;
 end loop;
 return added;
end $$;
revoke all on function public.enqueue_due_reminders() from public,anon,authenticated;

-- A worker claims a bounded batch atomically. Its response contains only the data needed
-- for an approved-template send; the function is inaccessible to browser roles.
create or replace function public.claim_reminder_runs(batch_size integer default 25) returns setof jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
 return query
 with candidates as (
  select run.id from public.reminder_runs run
  join public.reminders reminder on reminder.id=run.reminder_id and reminder.business_id=run.business_id
  where run.status in ('queued','retry_wait') and coalesce(run.next_attempt_at,now())<=now()
    and reminder.status in ('scheduled','queued') and reminder.mode='cloud'
  order by coalesce(run.next_attempt_at,run.scheduled_for),run.created_at
  for update of run skip locked limit greatest(1,least(coalesce(batch_size,25),100))
 ), claimed as (
  update public.reminder_runs run set status='processing',attempt_count=run.attempt_count+1,locked_at=now(),updated_at=now()
  from candidates where run.id=candidates.id returning run.*
 )
 select to_jsonb(claimed) || jsonb_build_object(
   'reminder',jsonb_build_object('id',reminder.id,'business_id',reminder.business_id,'contact_id',reminder.contact_id,'title',reminder.title,'phone',reminder.phone,'due_at',reminder.due_at,'timezone',reminder.timezone,'recurrence',reminder.recurrence,'mode',reminder.mode,'status',reminder.status,'template_id',reminder.template_id,'template_values',reminder.template_values),
   'contact',case when contact.id is null then null else jsonb_build_object('id',contact.id,'name',contact.name,'phone',contact.phone,'consent',contact.consent,'consent_recorded_at',contact.consent_recorded_at,'consent_source',contact.consent_source,'opted_out',contact.opted_out) end,
   'business',jsonb_build_object('name',business.name),
   'template',case when template.id is null then null else jsonb_build_object('id',template.id,'body',template.body,'meta_template_name',template.meta_template_name,'meta_language',template.meta_language,'meta_approved',template.meta_approved) end,
   'connection_count',(select count(*) from public.whatsapp_connections active where active.business_id=claimed.business_id and active.status='active'),
   'connection',case when connection.id is null then null else jsonb_build_object('phone_number_id',connection.phone_number_id,'token_ciphertext',encode(connection.token_ciphertext,'hex'),'token_iv',encode(connection.token_iv,'hex'),'status',connection.status) end
 )
 from claimed
 join public.reminders reminder on reminder.id=claimed.reminder_id and reminder.business_id=claimed.business_id
 join public.businesses business on business.id=claimed.business_id
 left join public.contacts contact on contact.id=reminder.contact_id and contact.business_id=reminder.business_id
 left join public.templates template on template.id=reminder.template_id and template.business_id=reminder.business_id
 left join public.whatsapp_connections connection on connection.business_id=claimed.business_id and connection.status='active'
  and (select count(*) from public.whatsapp_connections active where active.business_id=claimed.business_id and active.status='active')=1;
end $$;
revoke all on function public.claim_reminder_runs(integer) from public,anon,authenticated;
grant execute on function public.claim_reminder_runs(integer) to service_role;

-- Do not resend a run after a worker disappears mid-request: Cloud API may have accepted
-- the send before the worker lost its response. Move stale claims to manual reconciliation.
create or replace function public.mark_stale_reminder_runs() returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare changed integer;
begin
 update public.reminder_runs set status='delivery_unknown',locked_at=null,last_error_code='worker_interrupted',
  last_error_safe='Worker stopped during delivery; check WhatsApp Manager before retrying.',updated_at=now()
 where status='processing' and locked_at<now()-interval '10 minutes';
 get diagnostics changed=row_count;
 insert into public.message_logs(business_id,reminder_id,reminder_run_id,recipient_phone,mode,message,status,failure_code)
 select run.business_id,run.reminder_id,run.id,reminder.phone,'cloud',reminder.message,'delivery_unknown','worker_interrupted'
 from public.reminder_runs run join public.reminders reminder on reminder.id=run.reminder_id
 where run.status='delivery_unknown' and run.last_error_code='worker_interrupted'
  and not exists(select 1 from public.message_logs log where log.reminder_run_id=run.id and log.status='delivery_unknown');
 delete from public.provider_status_events where created_at<now()-interval '30 days';
 return changed;
end $$;
revoke all on function public.mark_stale_reminder_runs() from public,anon,authenticated;
grant execute on function public.mark_stale_reminder_runs() to service_role;

-- Operational setup is intentionally not enabled by this migration. After the function,
-- Meta onboarding, direct customer billing and operational monitoring are verified, store
-- the URL and bearer secret in Vault, then schedule enqueue + dispatch + reconciliation:
-- select vault.create_secret('https://PROJECT_REF.supabase.co/functions/v1/dispatch-reminders','wrp_dispatch_url');
-- select vault.create_secret('RANDOM_WORKER_BEARER_SECRET','wrp_dispatch_secret');
-- select cron.schedule('wrp-enqueue-every-minute','* * * * *', $$select public.enqueue_due_reminders();$$);
-- select cron.schedule('wrp-dispatch-every-minute','* * * * *', $$
--  select net.http_post(
--   url:=(select decrypted_secret from vault.decrypted_secrets where name='wrp_dispatch_url'),
--   headers:=jsonb_build_object('content-type','application/json','authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='wrp_dispatch_secret')),
--   body:='{}'::jsonb
--  );
-- $$);
-- select cron.schedule('wrp-reconcile-every-five-minutes','*/5 * * * *', $$select public.mark_stale_reminder_runs();$$);
-- The dispatcher Edge Function is present in supabase/functions/dispatch-reminders. It remains
-- disabled until token onboarding/encryption, customer-owned billing, and Meta approval are verified.
