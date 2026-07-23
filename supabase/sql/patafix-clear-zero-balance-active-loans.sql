-- PataFix cleanup: move cleared zero-balance loans out of Active Loans.
-- Run this once in Supabase SQL Editor after deploying the updated index.html.

update public.loans
set
  status = 'completed',
  outstanding_balance = 0,
  arrears_amount = 0,
  overdue_days = 0,
  updated_at = now()
where status = 'active'
  and coalesce(outstanding_balance, 0) <= 0.01;

update public.loan_schedules s
set
  status = 'paid',
  total_paid = greatest(coalesce(s.total_paid, 0), coalesce(s.total_due, 0)),
  paid_at = coalesce(s.paid_at, now()),
  updated_at = now()
where s.loan_id in (
  select id
  from public.loans
  where status = 'completed'
    and coalesce(outstanding_balance, 0) <= 0.01
)
and coalesce(s.total_due, 0) <= coalesce(s.total_paid, 0) + 0.01;

select
  count(*) filter (where status = 'active' and coalesce(outstanding_balance, 0) <= 0.01) as remaining_zero_balance_active_loans,
  count(*) filter (where status = 'completed' and coalesce(outstanding_balance, 0) <= 0.01) as completed_zero_balance_loans
from public.loans;
