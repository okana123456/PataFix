-- Read-only check for the KES 500 Malindi arrears movement seen on 2026-11-16.
-- Covers Nicholus's complete Malindi portfolio, not only the repaired loans.

with target_loans as (
  select
    l.id as loan_id,
    l.loan_no,
    l.outstanding_balance,
    l.arrears_amount,
    l.overdue_days,
    c.full_name,
    c.id_number,
    s.name as officer
  from public.loans l
  join public.loan_clients c on c.id = l.client_id
  left join public.loan_staff s on s.id = l.loan_officer_id
  where l.business_id = 'BIZ-58D22296'
    and l.status = 'active'
    and coalesce(l.branch_name,c.branch_name) = 'Malindi Branch'
    and lower(coalesce(s.name,'')) like 'nicholus%'
), recent_repayments as (
  select
    repayment.*,
    target.full_name,
    target.loan_no,
    target.id_number,
    target.officer
  from public.loan_repayments repayment
  join target_loans target on target.loan_id = repayment.loan_id
  where repayment.business_id = 'BIZ-58D22296'
    and timezone('Africa/Nairobi', repayment.payment_date)::date >= date '2026-11-14'
), suspicious_rows as (
  select schedule.*
  from public.loan_schedules schedule
  join target_loans target on target.loan_id = schedule.loan_id
  where schedule.business_id = 'BIZ-58D22296'
    and coalesce(schedule.installment_no,0) >= 1000000
)
select
  '1. RECENT REPAYMENT' as section,
  timezone('Africa/Nairobi', repayment.payment_date)::text as event_time_kenya,
  repayment.full_name as client,
  repayment.loan_no,
  coalesce(repayment.payment_reference, repayment.receipt_no) as reference,
  repayment.amount::numeric(14,2) as amount,
  jsonb_build_object(
    'officer', repayment.officer,
    'id_number', repayment.id_number,
    'method', repayment.payment_method,
    'receipt_no', repayment.receipt_no,
    'notes', repayment.notes
  ) as details
from recent_repayments repayment

union all

select
  '2. CURRENT LOAN BALANCE',
  null,
  target.full_name,
  target.loan_no,
  null,
  target.arrears_amount::numeric(14,2),
  jsonb_build_object(
    'officer', target.officer,
    'outstanding_balance', target.outstanding_balance,
    'overdue_days', target.overdue_days,
    'finding', 'Current restored loan position'
  )
from target_loans target

union all

select
  '3. SCHEDULE SAFEGUARD CHECK',
  timezone('Africa/Nairobi', suspicious.created_at)::text,
  target.full_name,
  target.loan_no,
  suspicious.id::text,
  greatest(suspicious.total_due - suspicious.total_paid,0)::numeric(14,2),
  jsonb_build_object(
    'installment_no', suspicious.installment_no,
    'due_date', suspicious.due_date,
    'status', suspicious.status,
    'finding', 'Unexpected high-number replacement schedule still exists'
  )
from suspicious_rows suspicious
join target_loans target on target.loan_id = suspicious.loan_id

order by section, event_time_kenya nulls last, client;
