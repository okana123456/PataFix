-- PataFix: move known suspense fee payments into client Charges & Excess accounts.
-- Use this only for old/current suspense items after confirming the correct client.
--
-- Normal future workflow:
-- 1. If the client already exists, use Suspense Account -> Match to Charges.
-- 2. If the client does not exist, create the client first, then match the payment.
--
-- Account-reference rule going forward:
-- - Clients continue using their National ID as the M-Pesa account number.
-- - A matched client with an active loan is routed to repayments.
-- - A matched client without an active loan is routed to Charges & Excess.
-- - An unknown client or mismatched reference remains in Suspense.

-- First, review current pending suspense items.
select
  'mpesa_queue' as source,
  q.id::text as source_id,
  q.trans_id as mpesa_reference,
  q.bill_ref_number as account_ref,
  q.msisdn as payer_phone,
  q.first_name as payer_name,
  q.trans_amount as amount,
  q.created_at
from public.mpesa_callback_queue q
where coalesce(q.confirmed,false) = false
union all
select
  'unmatched_payments' as source,
  u.id::text as source_id,
  coalesce(u.mpesa_reference,u.invoice_id) as mpesa_reference,
  u.account_number as account_ref,
  u.payer_phone,
  u.payer_name,
  u.amount,
  u.created_at
from public.unmatched_payments u
where coalesce(u.resolved,false) = false
order by created_at desc;

-- Then edit the rows below. Put the correct client_id for each M-Pesa ref.
-- charge_type can be: 'processing', 'registration', or 'other'
with rows_to_move as (
  select *
  from (
    values
      -- ('BIZ-8F2D366E','CLIENT_UUID_HERE','UH4NY1K4J8',700.00,'other','Registration and processing paid together')
      (null::text,null::uuid,null::text,null::numeric,null::text,null::text)
  ) as v(business_id, client_id, mpesa_reference, amount, charge_type, notes)
  where business_id is not null
),
inserted as (
  insert into public.client_charge_transactions (
    business_id,
    client_id,
    transaction_type,
    charge_type,
    amount,
    transaction_date,
    reference,
    payment_method,
    description,
    source_key
  )
  select
    r.business_id,
    r.client_id,
    'deposit',
    case when r.charge_type in ('processing','registration','other') then r.charge_type else 'other' end,
    round(r.amount,2),
    current_date,
    r.mpesa_reference,
    'mpesa',
    'Moved from suspense to Charges & Excess Account' || coalesce(' - ' || nullif(r.notes,''),''),
    'suspense-charge:' || r.mpesa_reference
  from rows_to_move r
  on conflict (business_id, source_key) where source_key is not null do nothing
  returning business_id, client_id, reference, amount
),
journaled as (
  insert into public.journal_entries (
    business_id,
    date,
    ref,
    description,
    debit,
    credit,
    amount,
    synced
  )
  select
    i.business_id,
    current_date,
    i.reference,
    'Suspense fee payment moved to Charges & Excess Account | Client ID: ' || i.client_id::text,
    'Suspense Account',
    'Charges & Excess Account',
    i.amount,
    false
  from inserted i
  returning ref
),
queue_done as (
  update public.mpesa_callback_queue q
  set confirmed = true,
      updated_at = now()
  from rows_to_move r
  where q.trans_id = r.mpesa_reference
  returning q.trans_id
),
unmatched_done as (
  update public.unmatched_payments u
  set resolved = true,
      resolved_at = now()
  from rows_to_move r
  where u.business_id = r.business_id
    and coalesce(u.mpesa_reference,u.invoice_id) = r.mpesa_reference
  returning coalesce(u.mpesa_reference,u.invoice_id) as ref
)
select
  (select count(*) from inserted) as charge_wallet_rows_created,
  (select count(*) from journaled) as journal_rows_created,
  (select count(*) from queue_done) as mpesa_queue_rows_closed,
  (select count(*) from unmatched_done) as unmatched_rows_resolved;
