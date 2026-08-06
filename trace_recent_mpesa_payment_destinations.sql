-- PataFix: trace where every recent Safaricom C2B payment went.
-- Read-only diagnostic. This query does not update or delete anything.
-- Change the date below if an earlier period needs to be checked.

with patafix_settings as (
  select business_id,mpesa_shortcode
  from public.loan_settings
  where business_id = 'BIZ-58D22296'
),
callbacks as (
  select q.*
  from public.mpesa_callback_queue q
  where q.created_at >= timestamptz '2026-08-04 00:00:00+03'
    and (
      q.business_id = 'BIZ-58D22296'
      or q.business_short_code in (
        select mpesa_shortcode from patafix_settings
        where nullif(mpesa_shortcode,'') is not null
      )
    )
)
select
  q.created_at at time zone 'Africa/Nairobi' as received_at_kenya,
  q.trans_id as mpesa_reference,
  q.trans_amount as amount,
  q.msisdn as payee_number_received,
  q.first_name as payee_name_received,
  q.bill_ref_number as account_reference,
  q.business_short_code as paybill_shortcode,
  q.business_id,
  q.confirmed as queue_confirmed,
  q.unmatched as queue_flagged_unmatched,
  q.unmatched_reason,
  coalesce(rp.entry_count,0) as repayment_entries,
  coalesce(rp.total_amount,0) as repayment_amount,
  rp.clients as repayment_clients,
  coalesce(ch.entry_count,0) as charges_entries,
  coalesce(ch.total_amount,0) as charges_amount,
  ch.clients as charges_clients,
  coalesce(sp.entry_count,0) as suspense_entries,
  coalesce(sp.pending_count,0) as pending_suspense_entries,
  case
    when coalesce(rp.entry_count,0) > 0 and coalesce(ch.entry_count,0) > 0
      then 'LOAN REPAYMENT + EXCESS IN CHARGES'
    when coalesce(rp.entry_count,0) > 0
      then 'LOAN REPAYMENT'
    when coalesce(ch.entry_count,0) > 0
      then 'CHARGES & EXCESS'
    when coalesce(sp.pending_count,0) > 0
      then 'SUSPENSE - PENDING MATCH'
    when coalesce(sp.entry_count,0) > 0
      then 'SUSPENSE - ALREADY RESOLVED'
    when q.business_id is null
      then 'CALLBACK RECEIVED - BUSINESS WAS NOT ATTACHED'
    when coalesce(q.unmatched,false)
      then 'FLAGGED UNMATCHED - SUSPENSE ROW IS MISSING'
    when not coalesce(q.confirmed,false)
      then 'DARAJA QUEUE - WAITING FOR MANUAL ACTION'
    else 'CONFIRMED BUT NO LINKED FINANCIAL RECORD - INVESTIGATE'
  end as current_destination
from callbacks q
left join lateral (
  select
    count(*) as entry_count,
    sum(r.amount) as total_amount,
    string_agg(distinct coalesce(c.full_name,'Unknown client'),', ') as clients
  from public.loan_repayments r
  left join public.loans l on l.id = r.loan_id
  left join public.loan_clients c on c.id = l.client_id
  where r.business_id = 'BIZ-58D22296'
    and (r.payment_reference = q.trans_id or r.receipt_no = q.trans_id)
) rp on true
left join lateral (
  select
    count(*) as entry_count,
    sum(t.amount) as total_amount,
    string_agg(distinct coalesce(c.full_name,'Unknown client'),', ') as clients
  from public.client_charge_transactions t
  left join public.loan_clients c on c.id = t.client_id
  where t.business_id = 'BIZ-58D22296'
    and t.reference = q.trans_id
    and t.transaction_type in ('deposit','excess_deposit')
) ch on true
left join lateral (
  select
    count(*) as entry_count,
    count(*) filter (where not coalesce(u.resolved,false)) as pending_count
  from public.unmatched_payments u
  where u.business_id = 'BIZ-58D22296'
    and coalesce(u.mpesa_reference,u.invoice_id) = q.trans_id
) sp on true
order by q.created_at desc,q.trans_id;

