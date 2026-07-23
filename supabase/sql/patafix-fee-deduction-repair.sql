-- PataFix fee deduction repair
-- Purpose:
-- 1. Existing loans that were saved with full principal as disbursed_amount
--    will be corrected so disbursed_amount becomes:
--    principal_amount - processing_fee - first-loan registration_fee.
-- 2. The repayable balance is not changed. Clients still repay the full
--    loan amount plus interest. This only fixes the amount released to client.

with ranked_loans as (
  select
    l.id,
    l.business_id,
    l.client_id,
    l.loan_no,
    l.principal_amount,
    l.disbursed_amount,
    coalesce(
      nullif(l.processing_fee, 0),
      case when l.principal_amount <= 5000 then 250 else 500 end
    ) as effective_processing_fee,
    row_number() over (
      partition by l.business_id, l.client_id
      order by coalesce(l.disbursement_date, l.created_at::date), l.created_at, l.id
    ) as loan_position
  from public.loans l
),
calculated as (
  select
    id,
    business_id,
    client_id,
    loan_no,
    principal_amount,
    disbursed_amount,
    effective_processing_fee,
    case when loan_position = 1 then 500 else 0 end as registration_fee,
    greatest(
      0,
      principal_amount
        - effective_processing_fee
        - case when loan_position = 1 then 500 else 0 end
    ) as corrected_disbursed_amount
  from ranked_loans
),
updated as (
  update public.loans l
  set
    processing_fee = c.effective_processing_fee,
    disbursed_amount = c.corrected_disbursed_amount
  from calculated c
  where l.id = c.id
    -- Only repair loans that still show full principal released.
    and abs(coalesce(l.disbursed_amount, 0) - coalesce(l.principal_amount, 0)) < 0.01
    and abs(coalesce(l.disbursed_amount, 0) - coalesce(c.corrected_disbursed_amount, 0)) >= 0.01
  returning
    l.id,
    l.business_id,
    l.loan_no,
    c.principal_amount,
    c.effective_processing_fee as processing_fee_deducted,
    c.registration_fee as registration_fee_deducted,
    c.disbursed_amount as old_disbursed_amount,
    c.corrected_disbursed_amount as new_disbursed_amount
)
select *
from updated
order by business_id, loan_no;
