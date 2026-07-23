-- PataFix secure business registration
-- Run this once in the Supabase SQL Editor after the main database setup.

-- Resolve the signed-in staff member's business. Keeping this helper here
-- makes this security patch safe to run even if an earlier setup was partial.
create or replace function public.current_patafix_business_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select business_id
  from public.loan_staff
  where auth_user_id = auth.uid()
    and is_active = true
  limit 1;
$$;

revoke all on function public.current_patafix_business_id() from public;
grant execute on function public.current_patafix_business_id()
to anon, authenticated, service_role;

alter table public.loan_staff enable row level security;

drop policy if exists patafix_staff_insert on public.loan_staff;

create policy patafix_staff_insert
on public.loan_staff
for insert
to authenticated
with check (
  business_id = public.current_patafix_business_id()
);

-- The register-patafix-business Edge Function uses the service role and
-- can create the first administrator. Signed-in users cannot create a new
-- business or attach themselves to another business through the public API.
