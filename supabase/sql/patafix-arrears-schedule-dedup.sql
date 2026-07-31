-- PataFix arrears schedule safeguard and repair.
-- Run once in the PataFix Supabase SQL Editor.
-- Legitimate instalments with different instalment numbers are not changed.

begin;

create table if not exists public.patafix_duplicate_schedule_merge_20260731 (
  loan_id uuid not null,
  installment_no integer not null,
  keep_id uuid not null,
  due_date date not null,
  principal_due numeric(14,2) not null,
  interest_due numeric(14,2) not null,
  total_due numeric(14,2) not null,
  principal_paid numeric(14,2) not null,
  interest_paid numeric(14,2) not null,
  total_paid numeric(14,2) not null,
  penalty_charged numeric(14,2) not null,
  paid_at timestamptz,
  duplicate_count bigint not null,
  primary key (loan_id, installment_no)
);

alter table public.patafix_duplicate_schedule_merge_20260731 enable row level security;
revoke all on table public.patafix_duplicate_schedule_merge_20260731 from anon, authenticated;
grant all on table public.patafix_duplicate_schedule_merge_20260731 to service_role;

delete from public.patafix_duplicate_schedule_merge_20260731;

insert into public.patafix_duplicate_schedule_merge_20260731
select
  loan_id,
  installment_no,
  (array_agg(id order by total_paid desc, updated_at desc, created_at desc))[1] as keep_id,
  min(due_date) as due_date,
  max(principal_due) as principal_due,
  max(interest_due) as interest_due,
  max(total_due) as total_due,
  least(max(principal_due), sum(principal_paid)) as principal_paid,
  least(max(interest_due), sum(interest_paid)) as interest_paid,
  least(max(total_due), sum(total_paid)) as total_paid,
  max(penalty_charged) as penalty_charged,
  max(paid_at) as paid_at,
  count(*) as duplicate_count
from public.loan_schedules
group by loan_id, installment_no
having count(*) > 1;

-- Keep a recoverable copy of every row that this repair may merge.
create table if not exists public.patafix_schedule_duplicate_backup_20260731
as select * from public.loan_schedules with no data;

alter table public.patafix_schedule_duplicate_backup_20260731 enable row level security;
revoke all on table public.patafix_schedule_duplicate_backup_20260731 from anon, authenticated;
grant all on table public.patafix_schedule_duplicate_backup_20260731 to service_role;

insert into public.patafix_schedule_duplicate_backup_20260731
select schedule.*
from public.loan_schedules schedule
join public.patafix_duplicate_schedule_merge_20260731 duplicate
  on duplicate.loan_id = schedule.loan_id
 and duplicate.installment_no = schedule.installment_no
where not exists (
  select 1
  from public.patafix_schedule_duplicate_backup_20260731 backup
  where backup.id = schedule.id
);

update public.loan_schedules schedule
set due_date = duplicate.due_date,
    principal_due = duplicate.principal_due,
    interest_due = duplicate.interest_due,
    total_due = duplicate.total_due,
    principal_paid = duplicate.principal_paid,
    interest_paid = duplicate.interest_paid,
    total_paid = duplicate.total_paid,
    penalty_charged = duplicate.penalty_charged,
    paid_at = duplicate.paid_at,
    status = case
      when duplicate.total_paid >= duplicate.total_due then 'paid'
      when duplicate.total_paid > 0 then 'partial'
      when duplicate.due_date < current_date then 'overdue'
      else 'pending'
    end,
    updated_at = now()
from public.patafix_duplicate_schedule_merge_20260731 duplicate
where schedule.id = duplicate.keep_id;

delete from public.loan_schedules schedule
using public.patafix_duplicate_schedule_merge_20260731 duplicate
where schedule.loan_id = duplicate.loan_id
  and schedule.installment_no = duplicate.installment_no
  and schedule.id <> duplicate.keep_id;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.loan_schedules'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) = 'UNIQUE (loan_id, installment_no)'
  ) then
    alter table public.loan_schedules
      add constraint loan_schedules_loan_installment_unique
      unique (loan_id, installment_no);
  end if;
end $$;

select
  coalesce(sum(duplicate_count - 1), 0) as duplicate_rows_removed,
  count(*) as affected_loan_instalments
from public.patafix_duplicate_schedule_merge_20260731;

commit;
