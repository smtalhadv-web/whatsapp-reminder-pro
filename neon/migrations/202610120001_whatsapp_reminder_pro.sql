-- WhatsApp Reminder Pro schema for Neon Postgres + Managed Better Auth + Data API.
-- All application access from the browser is restricted by GRANTs and tenant RLS.
-- Server workers use a separate server-only Neon database connection.

create extension if not exists pgcrypto;

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 160),
  timezone text not null default 'Asia/Karachi',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Managed Better Auth IDs arrive as the JWT subject and remain text here so this
-- product schema does not couple itself to Neon Auth's internal table layout.
create table public.business_members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id text not null,
  role text not null default 'owner' check (role in ('owner','admin','member','viewer')),
  created_at timestamptz not null default now(),
  primary key (business_id,user_id)
);
create index business_members_user_idx on public.business_members(user_id);

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 200),
  phone text not null check (phone ~ '^[+][1-9][0-9]{7,14}$'),
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
  check (not opted_out or not consent),
  check (not consent or (consent_recorded_at is not null and nullif(trim(consent_source),'') is not null))
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
  updated_at timestamptz not null default now(),
  unique(business_id,id)
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
  phone text not null check (phone ~ '^[+][1-9][0-9]{7,14}$'),
  message text not null,
  due_at timestamptz not null,
  timezone text not null default 'Asia/Karachi',
  recurrence text check (recurrence in ('daily','weekly','monthly','yearly',null)),
  recurrence_rule jsonb,
  mode text not null default 'manual' check (mode in ('manual','cloud')),
  status text not null default 'scheduled' check (status in ('scheduled','queued','paused','cancelled','sent','failed','awaiting_manual')),
  template_id uuid,
  template_values jsonb not null default '{}',
  idempotency_key text not null default encode(gen_random_bytes(16),'hex'),
  next_run_at timestamptz,
  last_run_at timestamptz,
  cancelled_at timestamptz,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key(business_id,contact_id) references public.contacts(business_id,id) on delete set null (contact_id),
  foreign key(business_id,template_id) references public.templates(business_id,id) on delete set null (template_id),
  unique(business_id,id),
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
  unique(business_id,id),
  unique(reminder_id,occurrence_key)
);
create index reminder_runs_queue_idx on public.reminder_runs(status,next_attempt_at,created_at);

create table public.message_logs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  reminder_id uuid,
  reminder_run_id uuid,
  recipient_phone text not null,
  mode text not null check(mode in ('manual','cloud')),
  message text not null,
  status text not null,
  provider_message_id text unique,
  failure_code text,
  created_at timestamptz not null default now(),
  foreign key(business_id,reminder_id) references public.reminders(business_id,id) on delete set null (reminder_id),
  foreign key(business_id,reminder_run_id) references public.reminder_runs(business_id,id) on delete set null (reminder_run_id)
);
create index message_logs_tenant_created_idx on public.message_logs(business_id,created_at desc);

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

create table public.audit_logs (
  id bigint generated always as identity primary key,
  business_id uuid references public.businesses(id) on delete cascade,
  actor_user_id text,
  action text not null,
  object_type text,
  object_id text,
  safe_details jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path=pg_catalog,public as $$
begin new.updated_at=now(); return new; end $$;
create trigger touch_businesses before update on public.businesses for each row execute function public.touch_updated_at();
create trigger touch_contacts before update on public.contacts for each row execute function public.touch_updated_at();
create trigger touch_templates before update on public.templates for each row execute function public.touch_updated_at();
create trigger touch_reminders before update on public.reminders for each row execute function public.touch_updated_at();
create trigger touch_runs before update on public.reminder_runs for each row execute function public.touch_updated_at();
create trigger touch_connections before update on public.whatsapp_connections for each row execute function public.touch_updated_at();

-- Keep the JWT helper outside the Data API's exposed public schema. The Data API
-- verifies the token and sets request.jwt.claims before PostgreSQL evaluates RLS.
create schema private;
revoke all on schema private from public,anonymous,authenticated;
grant usage on schema private to authenticated;
create or replace function private.current_user_id()
returns text language sql stable security definer set search_path=pg_catalog as $$
  select current_setting('request.jwt.claims',true)::jsonb ->> 'sub'
$$;
revoke all on function private.current_user_id() from public,anonymous;
grant execute on function private.current_user_id() to authenticated;

-- Create a workspace on first authenticated data load. The caller ID comes from
-- the verified Data API JWT, never from a user-supplied parameter.
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

-- Membership RLS uses the Data API's verified JWT subject. Membership queries
-- are self-filtering, so policies never trust business_id supplied by a client.
alter table public.businesses enable row level security;
alter table public.business_members enable row level security;
alter table public.contacts enable row level security;
alter table public.templates enable row level security;
alter table public.whatsapp_connections enable row level security;
alter table public.reminders enable row level security;
alter table public.reminder_runs enable row level security;
alter table public.message_logs enable row level security;
alter table public.provider_status_events enable row level security;
alter table public.audit_logs enable row level security;

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
-- WhatsApp connection secrets and provider status events have no browser policies.

-- Explicit grants are intentionally narrower than the Data API defaults.
revoke all on all tables in schema public from public,anonymous,authenticated;
grant usage on schema public to authenticated;
grant select on public.businesses,public.business_members,public.contacts,public.templates,public.reminders,public.reminder_runs,public.message_logs,public.audit_logs to authenticated;
grant update on public.businesses to authenticated;
grant insert,update,delete on public.contacts,public.templates,public.reminders to authenticated;
grant insert on public.message_logs to authenticated;
grant execute on function public.ensure_business(text,text) to authenticated;

