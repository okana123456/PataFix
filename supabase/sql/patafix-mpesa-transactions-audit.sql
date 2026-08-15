-- PataFix: consolidated M-Pesa transaction audit support.
-- Run once before deploying the updated patafix-payment-callback function.

begin;

alter table public.mpesa_callback_queue
  add column if not exists delivery_count integer not null default 1,
  add column if not exists last_received_at timestamptz,
  add column if not exists processing_status text,
  add column if not exists processing_message text;

update public.mpesa_callback_queue
set
  delivery_count = greatest(1, coalesce(delivery_count, 1)),
  last_received_at = coalesce(last_received_at, created_at),
  processing_status = coalesce(
    nullif(processing_status, ''),
    case
      when unmatched then 'suspense'
      when repayment_id is not null then 'processed_repayment'
      when confirmed then 'processed'
      when loan_id is not null then 'pending_confirmation'
      else 'received'
    end
  );

alter table public.mpesa_callback_queue
  drop constraint if exists mpesa_callback_queue_delivery_count_check;

alter table public.mpesa_callback_queue
  add constraint mpesa_callback_queue_delivery_count_check
  check (delivery_count >= 1);

create index if not exists mpesa_callback_queue_business_created_idx
  on public.mpesa_callback_queue (business_id, created_at desc);

create index if not exists mpesa_callback_queue_business_account_idx
  on public.mpesa_callback_queue (business_id, bill_ref_number);

commit;

select
  count(*) as callback_transactions_prepared,
  count(*) filter (where confirmed) as confirmed,
  count(*) filter (where unmatched) as suspense,
  count(*) filter (where not confirmed and not unmatched) as pending
from public.mpesa_callback_queue;
