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

create temp table patafix_registration_fee_fix_preview as
with first_loans as (
  select distinct on (client_id)
    client_id,
    loan_no,
    principal_amount,
    coalesce(disbursement_date::date, created_at::date, current_date) as registration_date,
    case
      when principal_amount between 5000 and 10000 then 200
      when principal_amount between 11000 and 15000 then 300
      when principal_amount between 16000 and 40000 then 400
      else 0
    end as registration_fee
  from loans
  where client_id is not null
    and coalesce(principal_amount, 0) > 0
  order by client_id, disbursement_date asc nulls last, created_at asc nulls last
)
select
  c.id as client_id,
  c.full_name,
  f.loan_no,
  f.principal_amount,
  f.registration_fee,
  f.registration_date,
  c.notes as old_notes
from loan_clients c
join first_loans f on f.client_id = c.id
where f.registration_fee > 0
  and coalesce(c.notes, '') !~ '\[REG_FEE:';

select *
from patafix_registration_fee_fix_preview
order by full_name;

update loan_clients c
set notes = trim(
  regexp_replace(coalesce(c.notes, ''), '\s*\[REG_FEE_PENDING:[^\]]+\]\s*', ' ', 'g')
  || ' '
  || '[REG_FEE:' || p.registration_fee || ':' || p.registration_date || ']'
)
from patafix_registration_fee_fix_preview p
where c.id = p.client_id;

select
  count(*) as clients_marked_registration_paid,
  coalesce(sum(registration_fee), 0) as total_registration_fees_marked
from patafix_registration_fee_fix_preview;

commit;
