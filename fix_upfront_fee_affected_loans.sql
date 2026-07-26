-- PataFix repair: fees are paid upfront, so affected old loans should show
-- the full approved principal as the disbursed amount.
--
-- This only updates rows where disbursed_amount is lower than principal_amount
-- by an amount that looks like old processing/application/registration fee deduction.

begin;

create temp table patafix_upfront_fee_fix_preview as
select
  id,
  loan_no,
  business_id,
  principal_amount,
  disbursed_amount as old_disbursed_amount,
  processing_fee,
  principal_amount - disbursed_amount as deducted_difference,
  principal_amount as new_disbursed_amount
from loans
where coalesce(principal_amount, 0) > 0
  and coalesce(disbursed_amount, 0) > 0
  and coalesce(disbursed_amount, 0) < coalesce(principal_amount, 0)
  and (coalesce(principal_amount, 0) - coalesce(disbursed_amount, 0)) <= (coalesce(processing_fee, 0) + 500);

select *
from patafix_upfront_fee_fix_preview
order by loan_no;

update loans l
set disbursed_amount = p.new_disbursed_amount
from patafix_upfront_fee_fix_preview p
where l.id = p.id;

select
  count(*) as loans_fixed,
  coalesce(sum(deducted_difference), 0) as total_amount_restored
from patafix_upfront_fee_fix_preview;

commit;
