begin;

-- Keep future automatic penalties disabled.
insert into public.loan_settings (business_id, company_name, enable_rollover_penalties)
values ('BIZ-58D22296', 'PataFix', false)
on conflict (business_id) do update
set enable_rollover_penalties = false,
    updated_at = now();

-- Capture the exact penalty amounts currently included in each loan schedule.
-- This temporary table makes the script safe across the separate update statements.
create temporary table _patafix_penalty_waivers as
select
  l.id as loan_id,
  l.business_id,
  l.loan_no,
  c.full_name as client,
  coalesce((
    select sum(greatest(coalesce(s.penalty_charged, 0), 0))
    from public.loan_schedules s
    where s.loan_id = l.id
  ), 0)::numeric(14,2) as schedule_penalty,
  coalesce((
    select sum(greatest(coalesce(p.penalty_amount, 0), 0))
    from public.loan_penalties p
    where p.loan_id = l.id
      and p.is_waived = false
  ), 0)::numeric(14,2) as unwaived_penalty_records
from public.loans l
join public.loan_clients c on c.id = l.client_id
where l.business_id = 'BIZ-58D22296'
  and (
    exists (
      select 1 from public.loan_schedules s
      where s.loan_id = l.id and coalesce(s.penalty_charged, 0) > 0
    )
    or exists (
      select 1 from public.loan_penalties p
      where p.loan_id = l.id and p.is_waived = false
    )
  );

-- Preserve the penalty records for audit purposes, but mark every one as waived.
update public.loan_penalties p
set is_waived = true,
    waived_reason = 'Waived after PataFix discontinued all loan penalties',
    waived_by = null,
    waived_at = coalesce(p.waived_at, now())
where p.business_id = 'BIZ-58D22296'
  and p.is_waived = false;

-- Remove penalties from schedules and recalculate each affected installment status.
update public.loan_schedules s
set total_due = greatest(s.total_paid, s.total_due - coalesce(s.penalty_charged, 0)),
    penalty_charged = 0,
    status = case
      when s.total_paid >= greatest(s.total_paid, s.total_due - coalesce(s.penalty_charged, 0)) - 0.01 then 'paid'
      when s.due_date < current_date then 'overdue'
      when s.total_paid > 0 then 'partial'
      else 'pending'
    end,
    paid_at = case
      when s.total_paid >= greatest(s.total_paid, s.total_due - coalesce(s.penalty_charged, 0)) - 0.01
        then coalesce(
          s.paid_at,
          (select max(r.payment_date) from public.loan_repayments r where r.loan_id = s.loan_id),
          now()
        )
      else null
    end,
    updated_at = now()
where s.business_id = 'BIZ-58D22296'
  and coalesce(s.penalty_charged, 0) > 0;

-- Remove only the amount that the schedules confirm was added as a penalty.
update public.loans l
set total_payable = greatest(l.total_paid, l.total_payable - w.schedule_penalty),
    outstanding_balance = greatest(0, l.outstanding_balance - w.schedule_penalty),
    arrears_amount = greatest(0, l.arrears_amount - w.schedule_penalty),
    overdue_days = case
      when greatest(0, l.outstanding_balance - w.schedule_penalty) <= 0.01
        or greatest(0, l.arrears_amount - w.schedule_penalty) <= 0.01 then 0
      else l.overdue_days
    end,
    status = case
      when greatest(0, l.outstanding_balance - w.schedule_penalty) <= 0.01 then 'completed'
      else l.status
    end,
    updated_at = now()
from _patafix_penalty_waivers w
where l.id = w.loan_id
  and w.schedule_penalty > 0;

insert into public.loan_audit_log (
  business_id, user_id, action, table_name, record_id, old_value, new_value
)
select
  w.business_id,
  null,
  'all_penalties_waived',
  'loans',
  w.loan_id::text,
  jsonb_build_object(
    'schedule_penalty', w.schedule_penalty,
    'unwaived_penalty_records', w.unwaived_penalty_records
  ),
  jsonb_build_object(
    'client', w.client,
    'loan_no', w.loan_no,
    'penalty_removed_from_balance', w.schedule_penalty,
    'reason', 'PataFix discontinued all loan penalties'
  )
from _patafix_penalty_waivers w
where w.schedule_penalty > 0
   or w.unwaived_penalty_records > 0;

commit;

-- Return every affected loan for verification.
select
  w.client,
  w.loan_no,
  w.schedule_penalty as penalty_removed,
  w.unwaived_penalty_records as penalty_records_waived,
  l.status as loan_status,
  l.total_payable,
  l.total_paid,
  l.outstanding_balance,
  l.arrears_amount,
  l.overdue_days,
  case
    when l.outstanding_balance <= 0.01 then 'CLEARED'
    else 'BALANCE REMAINS WITHOUT PENALTY'
  end as result
from _patafix_penalty_waivers w
join public.loans l on l.id = w.loan_id
order by w.client, w.loan_no;
