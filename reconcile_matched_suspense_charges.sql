-- PataFix: reconcile old Suspense entries whose charge deposit already succeeded.
-- This script does not create, delete or alter any client charge amount.
-- It closes Suspense/Daraja records only when an exact suspense charge source_key
-- proves that the payment is already in the client's Charges account.

begin;

-- Restore accounting journals that the earlier browser error prevented.
insert into public.journal_entries (
  business_id,date,ref,description,debit,credit,amount,synced
)
select
  t.business_id,
  t.transaction_date,
  coalesce(t.reference,t.source_key),
  'Reconciled Suspense payment already deposited to Charges & Excess | Client ID: ' || t.client_id::text,
  'Suspense Account',
  'Charges & Excess Account',
  t.amount,
  false
from public.client_charge_transactions t
where t.transaction_type = 'deposit'
  and (
    t.source_key like 'suspense-charge:unmatched:%'
    or t.source_key like 'suspense-charge:mpesa:%'
  )
  and not exists (
    select 1
    from public.journal_entries j
    where j.business_id = t.business_id
      and j.ref = coalesce(t.reference,t.source_key)
      and j.credit = 'Charges & Excess Account'
      and j.amount = t.amount
  );

-- Close Suspense matching rows that have an exact completed charge deposit.
update public.unmatched_payments u
set resolved = true,
    resolved_at = coalesce(u.resolved_at,now())
where coalesce(u.resolved,false) = false
  and exists (
    select 1
    from public.client_charge_transactions t
    where t.business_id = u.business_id
      and t.transaction_type = 'deposit'
      and t.source_key = 'suspense-charge:unmatched:' || u.id::text
  );

-- Close raw Daraja queue rows matched directly or through their linked Suspense row.
update public.mpesa_callback_queue q
set confirmed = true,
    updated_at = now()
where coalesce(q.confirmed,false) = false
  and (
    exists (
      select 1
      from public.client_charge_transactions t
      where t.business_id = q.business_id
        and t.transaction_type = 'deposit'
        and t.source_key = 'suspense-charge:mpesa:' || q.id::text
    )
    or exists (
      select 1
      from public.client_charge_transactions t
      where t.business_id = q.business_id
        and t.transaction_type = 'deposit'
        and t.reference = q.trans_id
        and t.source_key like 'suspense-charge:unmatched:%'
    )
  );

-- Close a Suspense row linked to a directly matched Daraja queue row.
update public.unmatched_payments u
set resolved = true,
    resolved_at = coalesce(u.resolved_at,now())
where coalesce(u.resolved,false) = false
  and exists (
    select 1
    from public.mpesa_callback_queue q
    join public.client_charge_transactions t
      on t.business_id = q.business_id
     and t.transaction_type = 'deposit'
     and t.source_key = 'suspense-charge:mpesa:' || q.id::text
    where q.business_id = u.business_id
      and q.trans_id = coalesce(u.mpesa_reference,u.invoice_id)
  );

commit;

-- Final check: both counts should return zero after reconciliation.
select
  (select count(*)
   from public.unmatched_payments u
   join public.client_charge_transactions t
     on t.source_key = 'suspense-charge:unmatched:' || u.id::text
   where coalesce(u.resolved,false) = false) as matched_charges_still_in_suspense,
  (select count(*)
   from public.mpesa_callback_queue q
   join public.client_charge_transactions t
     on t.source_key = 'suspense-charge:mpesa:' || q.id::text
      or (t.business_id = q.business_id and t.reference = q.trans_id
          and t.source_key like 'suspense-charge:unmatched:%')
   where coalesce(q.confirmed,false) = false) as matched_charges_still_in_daraja_queue;

-- Review only. If rows appear here, share the result before changing money records.
-- This script deliberately does not delete possible duplicate charge deposits.
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
