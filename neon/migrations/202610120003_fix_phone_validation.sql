-- Preserve E.164 validation while matching the leading plus as a literal.
alter table public.contacts drop constraint contacts_phone_check;
alter table public.contacts add constraint contacts_phone_check
  check (phone ~ '^[+][1-9][0-9]{7,14}$');
alter table public.reminders drop constraint reminders_phone_check;
alter table public.reminders add constraint reminders_phone_check
  check (phone ~ '^[+][1-9][0-9]{7,14}$');
