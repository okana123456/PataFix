-- PataFix: reconcile old Suspense entries whose charge deposit already succeeded.
-- This script does not create, delete or alter any client charge amount.
-- It only closes Suspense/Daraja records when an exact suspense charge source_key
-- proves that the payment was already deposited into the client's Charges account.

begin;

create temporary table patafix_matched_suspense_charges on commit drop as
select
  t.business_id,
  t.client_id,
  t.id as charge_transaction_id,
  t.amount,
  t.transaction_date,
  t.reference as mpesa_reference,
  t.source_key,
  case
    when t.source_key like 'suspense-charge:unmatched:%'
      then replace(t.source_key,'suspense-charge:unmatched:','')
    else null
  end as unmatched_id_text,
  case
    when t.source_key like 'suspense-charge:mpesa:%'
      then replace(t.source_key,'suspense-charge:mpesa:','')
    else null
  end as queue_id_text
from public.client_charge_transactions t
where t.transaction_type = 'deposit'
  and (
    t.source_key like 'suspense-charge:unmatched:%'
    or t.source_key like 'suspense-charge:mpesa:%'
  );

-- Restore the accounting journal that the earlier browser error prevented.
insert into public.journal_entries (
  business_id,date,ref,description,debit,credit,amount,synced
)
select
  m.business_id,
  m.transaction_date,
  coalesce(m.mpesa_reference,m.source_key),
  'Reconciled Suspense payment already deposited to Charges & Excess | Client ID: ' || m.client_id::text,
  'Suspense Account',
  'Charges & Excess Account',
  m.amount,
  false
from patafix_matched_suspense_charges m
where not exists (
  select 1
  from public.journal_entries j
  where j.business_id = m.business_id
    and j.ref = coalesce(m.mpesa_reference,m.source_key)
    and j.credit = 'Charges & Excess Account'
    and j.amount = m.amount
);

with resolved_manual as (
  update public.unmatched_payments u
  set resolved = true,
      resolved_at = coalesce(u.resolved_at,now())
  from patafix_matched_suspense_charges m
  where u.id::text = m.unmatched_id_text
    and coalesce(u.resolved,false) = false
  returning u.business_id,coalesce(u.mpesa_reference,u.invoice_id) as mpesa_reference
),
matched_refs as (
  select business_id,mpesa_reference
  from patafix_matched_suspense_charges
  where nullif(mpesa_reference,'') is not null
  union
  select business_id,mpesa_reference
  from resolved_manual
  where nullif(mpesa_reference,'') is not null
)
update public.mpesa_callback_queue q
set confirmed = true,
    updated_at = now()
where coalesce(q.confirmed,false) = false
  and (
    exists (
      select 1 from patafix_matched_suspense_charges m
      where m.queue_id_text = q.id::text
    )
    or exists (
      select 1 from matched_refs r
      where r.business_id = q.business_id
        and r.mpesa_reference = q.trans_id
    )
  );

-- Close a manual row linked to a directly matched Daraja queue row.
update public.unmatched_payments u
set resolved = true,
    resolved_at = coalesce(u.resolved_at,now())
from patafix_matched_suspense_charges m
where m.queue_id_text is not null
  and m.business_id = u.business_id
  and m.mpesa_reference = u.mpesa_reference
  and coalesce(u.resolved,false) = false;

commit;

-- Final check: these counts should normally return zero after reconciliation.
select
  (select count(*)
   from public.unmatched_payments u
   join public.client_charge_transactions t
     on t.source_key = 'suspense-charge:unmatched:' || u.id::text
   where coalesce(u.resolved,false) = false) as matched_charges_still_in_manual_suspense,
  (select count(*)
   from public.mpesa_callback_queue q
   join public.client_charge_transactions t
     on t.source_key = 'suspense-charge:mpesa:' || q.id::text
      or (t.business_id = q.business_id and t.reference = q.trans_id
          and t.source_key like 'suspense-charge:unmatched:%')
   where coalesce(q.confirmed,false) = false) as matched_charges_still_in_daraja_queue;

-- Review only: any result here may be a genuine duplicate charge deposit and should
-- be inspected before changing money records. This script deliberately does not delete it.
select
  business_id,
  reference as mpesa_reference,
  count(*) as charge_deposit_entries,
  sum(amount) as total_deposited
from public.client_charge_transactions
where transaction_type in ('deposit','excess_deposit')
  and nullif(reference,'') is not null
group by business_id,reference
having count(*) > 1
order by charge_deposit_entries desc,mpesa_reference;
