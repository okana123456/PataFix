-- Read-only diagnosis of every live PataFix loan affected by the unaudited
-- 13 November 2026 schedule replacement. No records are changed.

with suspicious_schedule_rows as (
  select s.*
  from public.loan_schedules s
  where s.business_id = 'BIZ-58D22296'
    and timezone('Africa/Nairobi', s.created_at)::date = date '2026-11-13'
    and coalesce(s.installment_no, 0) >= 1000000
    and coalesce(s.interest_due, 0) = 0
), affected_loans as (
  select
    s.loan_id,
    count(*) as replacement_rows,
    min(s.due_date) as replacement_first_due,
    max(s.due_date) as replacement_last_due,
    round(sum(s.total_due), 2) as replacement_total_due,
    min(s.created_at) as replacement_created_at
  from suspicious_schedule_rows s
  group by s.loan_id
), repayment_totals as (
  select
    r.loan_id,
    count(*) as repayment_count,
    round(coalesce(sum(r.amount), 0), 2) as repayments_total,
    min(r.payment_date) as first_payment,
    max(r.payment_date) as last_payment
  from public.loan_repayments r
  join affected_loans a on a.loan_id = r.loan_id
  where r.business_id = 'BIZ-58D22296'
  group by r.loan_id
), retained_schedule_stats as (
  select
    s.loan_id,
    count(*) filter (
      where suspicious.id is null
    ) as retained_rows,
    min(s.due_date) filter (
      where suspicious.id is null
    ) as retained_first_due,
    max(s.due_date) filter (
      where suspicious.id is null
    ) as retained_last_due,
    round(coalesce(sum(s.total_due) filter (
      where suspicious.id is null
    ), 0), 2) as retained_total_due,
    round(coalesce(sum(s.total_paid) filter (
      where suspicious.id is null
    ), 0), 2) as retained_total_paid
  from public.loan_schedules s
  join affected_loans a on a.loan_id = s.loan_id
  left join suspicious_schedule_rows suspicious on suspicious.id = s.id
  group by s.loan_id
)
select
  coalesce(l.branch_name, c.branch_name, 'Unassigned') as branch,
  coalesce(staff.name, 'Unassigned') as loan_officer,
  c.full_name as client,
  c.id_number,
  c.phone,
  l.loan_no,
  l.status as loan_status,
  l.disbursement_date,
  l.first_repayment_date,
  l.maturity_date as shifted_maturity_date,
  l.first_repayment_date + ((l.term_weeks - 1) * 7) as expected_original_maturity,
  l.term_weeks,
  l.principal_amount,
  l.total_payable as shifted_total_payable,
  coalesce(r.repayments_total, 0) as repayments_total,
  l.outstanding_balance as shifted_outstanding,
  round(a.replacement_total_due / 1.05, 2) as inferred_original_outstanding,
  round(a.replacement_total_due - (a.replacement_total_due / 1.05), 2) as wrongly_added_five_percent,
  round(coalesce(r.repayments_total, 0) + (a.replacement_total_due / 1.05), 2) as inferred_original_total_payable,
  l.arrears_amount as stored_arrears,
  l.overdue_days as stored_overdue_days,
  a.replacement_rows,
  a.replacement_first_due,
  a.replacement_last_due,
  a.replacement_total_due,
  timezone('Africa/Nairobi', a.replacement_created_at) as replacement_created_kenya,
  coalesce(retained.retained_rows, 0) as retained_original_rows,
  retained.retained_first_due,
  retained.retained_last_due,
  retained.retained_total_due,
  retained.retained_total_paid,
  coalesce(r.repayment_count, 0) as repayment_count,
  r.first_payment,
  r.last_payment,
  case
    when a.replacement_rows = 3
      and a.replacement_total_due = l.outstanding_balance
      then 'CONFIRMED SAME SHIFT: future replacement schedule plus 5 percent'
    else 'REVIEW: suspicious 13 November replacement pattern'
  end as finding
from affected_loans a
join public.loans l
  on l.id = a.loan_id
 and l.business_id = 'BIZ-58D22296'
join public.loan_clients c
  on c.id = l.client_id
 and c.business_id = l.business_id
left join public.loan_staff staff
  on staff.id = l.loan_officer_id
 and staff.business_id = l.business_id
left join repayment_totals r on r.loan_id = l.id
left join retained_schedule_stats retained on retained.loan_id = l.id
order by
  coalesce(l.branch_name, c.branch_name, 'Unassigned'),
  coalesce(staff.name, 'Unassigned'),
  c.full_name;
