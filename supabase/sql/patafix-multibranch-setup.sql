-- PataFix multi-branch setup.
-- Run this in Supabase SQL Editor after deploying the updated index.html.

create extension if not exists pgcrypto;

create table if not exists public.patafix_branches (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  name text not null,
  branch_code text,
  manager_name text,
  phone text,
  location text,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, name)
);

alter table public.patafix_branches enable row level security;

drop policy if exists patafix_branches_select on public.patafix_branches;
drop policy if exists patafix_branches_insert on public.patafix_branches;
drop policy if exists patafix_branches_update on public.patafix_branches;
drop policy if exists patafix_branches_delete on public.patafix_branches;

create policy patafix_branches_select on public.patafix_branches
  for select using (
    exists (
      select 1 from public.loan_staff s
      where s.auth_user_id = auth.uid()
        and s.business_id = patafix_branches.business_id
        and s.is_active = true
    )
  );

create policy patafix_branches_insert on public.patafix_branches
  for insert with check (
    exists (
      select 1 from public.loan_staff s
      where s.auth_user_id = auth.uid()
        and s.business_id = patafix_branches.business_id
        and s.is_active = true
        and position('admin' in coalesce(s.role,'')) > 0
    )
  );

create policy patafix_branches_update on public.patafix_branches
  for update using (
    exists (
      select 1 from public.loan_staff s
      where s.auth_user_id = auth.uid()
        and s.business_id = patafix_branches.business_id
        and s.is_active = true
        and position('admin' in coalesce(s.role,'')) > 0
    )
  ) with check (
    exists (
      select 1 from public.loan_staff s
      where s.auth_user_id = auth.uid()
        and s.business_id = patafix_branches.business_id
        and s.is_active = true
        and position('admin' in coalesce(s.role,'')) > 0
    )
  );

create policy patafix_branches_delete on public.patafix_branches
  for delete using (
    exists (
      select 1 from public.loan_staff s
      where s.auth_user_id = auth.uid()
        and s.business_id = patafix_branches.business_id
        and s.is_active = true
        and position('admin' in coalesce(s.role,'')) > 0
    )
  );

create index if not exists patafix_branches_business_idx
  on public.patafix_branches (business_id, status, name);

alter table public.loan_staff add column if not exists branch_name text not null default 'Head Office';
alter table public.loan_clients add column if not exists branch_name text not null default 'Head Office';
alter table public.loan_applications add column if not exists branch_name text not null default 'Head Office';
alter table public.loans add column if not exists branch_name text not null default 'Head Office';
alter table public.loan_schedules add column if not exists branch_name text not null default 'Head Office';
alter table public.loan_repayments add column if not exists branch_name text not null default 'Head Office';
alter table public.loan_penalties add column if not exists branch_name text not null default 'Head Office';
alter table public.journal_entries add column if not exists branch_name text not null default 'Head Office';

insert into public.patafix_branches (business_id, name, branch_code, status)
select distinct business_id, 'Head Office', 'HO', 'active'
from public.loan_staff
where business_id is not null
on conflict (business_id, name) do nothing;

update public.loan_staff
set branch_name = 'Head Office'
where branch_name is null or trim(branch_name) = '';

update public.loan_clients c
set branch_name = coalesce(nullif(trim(s.branch_name),''),'Head Office')
from public.loan_staff s
where c.loan_officer_id = s.id
  and c.business_id = s.business_id
  and (c.branch_name is null or c.branch_name = 'Head Office');

update public.loan_applications a
set branch_name = coalesce(
  nullif(trim(c.branch_name),''),
  (
    select nullif(trim(s.branch_name),'')
    from public.loan_staff s
    where s.id = a.loan_officer_id
      and s.business_id = a.business_id
    limit 1
  ),
  'Head Office'
)
from public.loan_clients c
where a.client_id = c.id
  and a.business_id = c.business_id
  and (a.branch_name is null or a.branch_name = 'Head Office');

update public.loans l
set branch_name = coalesce(
  nullif(trim(c.branch_name),''),
  (
    select nullif(trim(s.branch_name),'')
    from public.loan_staff s
    where s.id = l.loan_officer_id
      and s.business_id = l.business_id
    limit 1
  ),
  'Head Office'
)
from public.loan_clients c
where l.client_id = c.id
  and l.business_id = c.business_id
  and (l.branch_name is null or l.branch_name = 'Head Office');

update public.loan_schedules sc
set branch_name = coalesce(nullif(trim(l.branch_name),''),'Head Office')
from public.loans l
where sc.loan_id = l.id
  and sc.business_id = l.business_id;

update public.loan_repayments r
set branch_name = coalesce(nullif(trim(l.branch_name),''),'Head Office')
from public.loans l
where r.loan_id = l.id
  and r.business_id = l.business_id;

update public.loan_penalties p
set branch_name = coalesce(nullif(trim(l.branch_name),''),'Head Office')
from public.loans l
where p.loan_id = l.id
  and p.business_id = l.business_id;

create index if not exists loan_staff_branch_idx on public.loan_staff (business_id, branch_name);
create index if not exists loan_clients_branch_idx on public.loan_clients (business_id, branch_name);
create index if not exists loan_applications_branch_idx on public.loan_applications (business_id, branch_name, status);
create index if not exists loans_branch_idx on public.loans (business_id, branch_name, status);
create index if not exists loan_schedules_branch_idx on public.loan_schedules (business_id, branch_name, due_date);
create index if not exists loan_repayments_branch_idx on public.loan_repayments (business_id, branch_name, payment_date);
create index if not exists loan_penalties_branch_idx on public.loan_penalties (business_id, branch_name, date_charged);
create index if not exists journal_entries_branch_idx on public.journal_entries (business_id, branch_name, date);

create or replace function public.patafix_fill_branch_name()
returns trigger
language plpgsql
as $$
begin
  if new.branch_name is null or trim(new.branch_name) = '' then
    if tg_table_name = 'loan_clients' then
      select coalesce(nullif(trim(s.branch_name),''),'Head Office')
        into new.branch_name
      from public.loan_staff s
      where s.id = new.loan_officer_id and s.business_id = new.business_id
      limit 1;
    elsif tg_table_name = 'loan_applications' then
      select coalesce(nullif(trim(c.branch_name),''), nullif(trim(s.branch_name),''), 'Head Office')
        into new.branch_name
      from public.loan_clients c
      left join public.loan_staff s on s.id = new.loan_officer_id and s.business_id = new.business_id
      where c.id = new.client_id and c.business_id = new.business_id
      limit 1;
    elsif tg_table_name = 'loans' then
      select coalesce(nullif(trim(c.branch_name),''), nullif(trim(s.branch_name),''), 'Head Office')
        into new.branch_name
      from public.loan_clients c
      left join public.loan_staff s on s.id = new.loan_officer_id and s.business_id = new.business_id
      where c.id = new.client_id and c.business_id = new.business_id
      limit 1;
    elsif tg_table_name = 'loan_schedules' then
      select coalesce(nullif(trim(l.branch_name),''),'Head Office')
        into new.branch_name
      from public.loans l
      where l.id = new.loan_id and l.business_id = new.business_id
      limit 1;
    elsif tg_table_name = 'loan_repayments' then
      select coalesce(nullif(trim(l.branch_name),''),'Head Office')
        into new.branch_name
      from public.loans l
      where l.id = new.loan_id and l.business_id = new.business_id
      limit 1;
    elsif tg_table_name = 'loan_penalties' then
      select coalesce(nullif(trim(l.branch_name),''),'Head Office')
        into new.branch_name
      from public.loans l
      where l.id = new.loan_id and l.business_id = new.business_id
      limit 1;
    end if;
  end if;
  new.branch_name = coalesce(nullif(trim(new.branch_name),''),'Head Office');
  return new;
end;
$$;

drop trigger if exists loan_clients_fill_branch_name on public.loan_clients;
create trigger loan_clients_fill_branch_name
before insert or update on public.loan_clients
for each row execute function public.patafix_fill_branch_name();

drop trigger if exists loan_applications_fill_branch_name on public.loan_applications;
create trigger loan_applications_fill_branch_name
before insert or update on public.loan_applications
for each row execute function public.patafix_fill_branch_name();

drop trigger if exists loans_fill_branch_name on public.loans;
create trigger loans_fill_branch_name
before insert or update on public.loans
for each row execute function public.patafix_fill_branch_name();

drop trigger if exists loan_schedules_fill_branch_name on public.loan_schedules;
create trigger loan_schedules_fill_branch_name
before insert or update on public.loan_schedules
for each row execute function public.patafix_fill_branch_name();

drop trigger if exists loan_repayments_fill_branch_name on public.loan_repayments;
create trigger loan_repayments_fill_branch_name
before insert or update on public.loan_repayments
for each row execute function public.patafix_fill_branch_name();

drop trigger if exists loan_penalties_fill_branch_name on public.loan_penalties;
create trigger loan_penalties_fill_branch_name
before insert or update on public.loan_penalties
for each row execute function public.patafix_fill_branch_name();

select
  'PataFix multi-branch setup complete' as status,
  count(*) filter (where status = 'active') as active_branches
from public.patafix_branches;
