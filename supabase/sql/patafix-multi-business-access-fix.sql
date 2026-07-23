-- PataFix multi-business access fix
-- Run this if the same login email/user can belong to more than one PataFix
-- business and one browser shows zero records while another business has data.

create or replace function public.patafix_can_access_business(target_business_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.loan_staff s
    where (
        s.auth_user_id = auth.uid()
        or lower(trim(s.email)) = lower(trim(coalesce(auth.jwt() ->> 'email', '')))
      )
      and s.is_active = true
      and s.business_id = target_business_id
  );
$$;

revoke all on function public.patafix_can_access_business(text) from public;
grant execute on function public.patafix_can_access_business(text) to anon, authenticated, service_role;

-- Keep the old helper for compatibility, but make normal policies use the
-- safer patafix_can_access_business(...) check below.
create or replace function public.current_patafix_business_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select business_id
  from public.loan_staff
  where (
      auth_user_id = auth.uid()
      or lower(trim(email)) = lower(trim(coalesce(auth.jwt() ->> 'email', '')))
    )
    and is_active = true
  order by last_login desc nulls last, created_at desc
  limit 1;
$$;

grant execute on function public.current_patafix_business_id() to anon, authenticated, service_role;

alter table public.loan_staff enable row level security;

drop policy if exists patafix_staff_select on public.loan_staff;
create policy patafix_staff_select on public.loan_staff
for select to authenticated
using (
  auth_user_id = auth.uid()
  or lower(trim(email)) = lower(trim(coalesce(auth.jwt() ->> 'email', '')))
  or public.patafix_can_access_business(business_id)
);

drop policy if exists patafix_staff_insert on public.loan_staff;
create policy patafix_staff_insert on public.loan_staff
for insert to authenticated
with check (public.patafix_can_access_business(business_id));

drop policy if exists patafix_staff_update on public.loan_staff;
create policy patafix_staff_update on public.loan_staff
for update to authenticated
using (
  auth_user_id = auth.uid()
  or lower(trim(email)) = lower(trim(coalesce(auth.jwt() ->> 'email', '')))
  or public.patafix_can_access_business(business_id)
)
with check (public.patafix_can_access_business(business_id));

drop policy if exists patafix_staff_delete on public.loan_staff;
create policy patafix_staff_delete on public.loan_staff
for delete to authenticated
using (public.patafix_can_access_business(business_id));

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'loan_settings','loan_clients','loan_products','loan_applications','loans',
    'loan_schedules','loan_repayments','loan_penalties','loan_follow_ups',
    'journal_entries','loan_audit_log','loan_billing_cycles',
    'mpesa_callback_queue','unmatched_payments'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);

    execute format('drop policy if exists patafix_business_select on public.%I', table_name);
    execute format('create policy patafix_business_select on public.%I for select to authenticated using (public.patafix_can_access_business(business_id))', table_name);

    execute format('drop policy if exists patafix_business_insert on public.%I', table_name);
    execute format('create policy patafix_business_insert on public.%I for insert to authenticated with check (public.patafix_can_access_business(business_id))', table_name);

    execute format('drop policy if exists patafix_business_update on public.%I', table_name);
    execute format('create policy patafix_business_update on public.%I for update to authenticated using (public.patafix_can_access_business(business_id)) with check (public.patafix_can_access_business(business_id))', table_name);

    execute format('drop policy if exists patafix_business_delete on public.%I', table_name);
    execute format('create policy patafix_business_delete on public.%I for delete to authenticated using (public.patafix_can_access_business(business_id))', table_name);
  end loop;
end $$;
