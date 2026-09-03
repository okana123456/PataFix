-- PataFix Gold / multi-branch subscription billing.
-- Run this once in Supabase SQL Editor after deploying the updated app.
-- September 2026 remains at KES 3,000. From October 2026 onward, billing is KES 7,500.

alter table public.loan_billing_cycles
  alter column amount set default 7500;

update public.loan_billing_cycles
set amount = 7500,
    updated_at = now()
where billing_month >= date '2026-10-01'
  and status in ('pending','initiated','failed')
  and coalesce(amount,0) <> 7500;

select
  'PataFix Gold billing ready' as result,
  3000::numeric(14,2) as amount_until_2026_09,
  7500::numeric(14,2) as amount_from_2026_10;
