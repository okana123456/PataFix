-- PataFix: remove only the three confirmed rapid double-submissions.
-- UGS1K0RJ5L is intentionally preserved: KES 500 processing + KES 200 registration.
-- TR 09/07 is intentionally preserved pending confirmation because its two entries
-- were submitted 20 minutes apart using a manually reused reference.

begin;

-- Remove the later charge-wallet row from each confirmed duplicate pair.
delete from public.client_charge_transactions
where business_id = 'BIZ-58D22296'
  and id in (
    '8cd99e94-0fe1-41eb-a4e0-3c8d6f351e77'::uuid, -- UGG3GBNHQ1, later KES 700 row
    '8a610136-286f-43a9-b596-707e792a637a'::uuid, -- UGHPVB8SUW, later KES 700 row
    '201122e8-466d-49b4-94c9-bde04d4c39a9'::uuid  -- UH33B26YXU, later KES 200 row
  );

-- Remove only the later duplicate accounting journal for those same receipts.
with ranked_duplicate_journals as (
  select
    j.id,
    row_number() over (
      partition by j.business_id,j.ref,j.amount,j.credit,j.description
      order by j.created_at,j.id
    ) as duplicate_no
  from public.journal_entries j
  where j.business_id = 'BIZ-58D22296'
    and j.ref in ('UGG3GBNHQ1','UGHPVB8SUW','UH33B26YXU')
    and j.credit = 'Charges & Excess Account'
)
delete from public.journal_entries j
using ranked_duplicate_journals r
where j.id = r.id
  and r.duplicate_no > 1;

commit;

-- Verification: these three references should now have one deposit each.
select
  reference as mpesa_reference,
  count(*) as charge_deposit_entries,
  sum(amount) as total_deposited
from public.client_charge_transactions
where business_id = 'BIZ-58D22296'
  and reference in ('UGG3GBNHQ1','UGHPVB8SUW','UH33B26YXU')
  and transaction_type = 'deposit'
group by reference
order by reference;

-- Check the corrected available balances for the affected clients.
select
  c.full_name as client,
  c.id_number,
  coalesce(sum(
    case
      when t.transaction_type in ('deposit','excess_deposit','adjustment_credit') then t.amount
      else -t.amount
    end
  ),0) as charges_available_balance
from public.loan_clients c
left join public.client_charge_transactions t
  on t.client_id = c.id and t.business_id = c.business_id
where c.business_id = 'BIZ-58D22296'
  and c.id_number in ('25808888','24374694','21989560')
group by c.id,c.full_name,c.id_number
order by c.full_name;
