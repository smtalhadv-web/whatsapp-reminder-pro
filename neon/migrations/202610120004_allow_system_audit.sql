-- Server-side jobs and migration tooling do not have an end-user JWT. Treat a
-- missing claim as a null actor so audit triggers still record system actions.
create or replace function private.current_user_id()
returns text
language sql
stable
security definer
set search_path = pg_catalog
as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
$$;

revoke all on function private.current_user_id() from public, anonymous;
grant execute on function private.current_user_id() to authenticated;
