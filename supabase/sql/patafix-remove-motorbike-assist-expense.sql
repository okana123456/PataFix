-- PataFix cleanup: remove the wrongly entered "motorbike assist" expense.
-- Run the PREVIEW first. If the row shown is the wrong expense, adjust the
-- words in the where clause before running the transaction.

-- 1) PREVIEW THE RECORD(S)
alter table public.patafix_expenses
  add column if not exists branch_name text not null default 'Head Office';

select
  id,
  business_id,
  expense_no,
  expense_date,
  branch_name,
  category,
  description,
  amount,
  payment_method,
  payment_reference,
  status,
  approved_at
from public.patafix_expenses
where lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%assist%'
  and (
    lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%moterbike%'
    or lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%motorbike%'
  );

-- 2) REMOVE THE RECORD(S) FROM EXPENSES AND THE MATCHING APPROVED JOURNAL ENTRY
begin;

with target_expense as (
  delete from public.patafix_expenses
  where lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%assist%'
    and (
      lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%moterbike%'
      or lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%motorbike%'
    )
  returning business_id, expense_no, payment_reference
),
target_refs as (
  select business_id, coalesce(payment_reference, expense_no) as ref
  from target_expense
)
delete from public.journal_entries j
using target_refs t
where j.business_id = t.business_id
  and j.ref = t.ref
  and lower(coalesce(j.description,'')) like '%approved expense%';

commit;

-- 3) CONFIRM NOTHING MATCHING THAT WORDING REMAINS
select
  id,
  expense_no,
  expense_date,
  category,
  description,
  amount,
  status
from public.patafix_expenses
where lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%assist%'
  and (
    lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%moterbike%'
    or lower(coalesce(category,'') || ' ' || coalesce(description,'')) like '%motorbike%'
  );
