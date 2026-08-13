-- One-time PataFix correction: remove Shadrack's KES 100,000 business
-- investment from pending suspense without recording a loan repayment or charge.

do $$
declare
  v_business_id text := 'BIZ-58D22296';
  v_suspense public.unmatched_payments%rowtype;
  v_match_count integer;
  v_resolved_at timestamptz := now();
begin
  select count(*)
  into v_match_count
  from public.unmatched_payments
  where business_id = v_business_id
    and resolved = false
    and amount = 100000
    and upper(trim(coalesce(payer_name, ''))) like '%SHADRACK%'
    and regexp_replace(coalesce(account_number, ''), '[^0-9]', '', 'g') = '27388490'
    and payment_date::date = date '2026-08-09';

  if v_match_count <> 1 then
    raise exception 'Safety check expected exactly one pending Shadrack KES 100,000 suspense entry, but found %.', v_match_count;
  end if;

  select *
  into v_suspense
  from public.unmatched_payments
  where business_id = v_business_id
    and resolved = false
    and amount = 100000
    and upper(trim(coalesce(payer_name, ''))) like '%SHADRACK%'
    and regexp_replace(coalesce(account_number, ''), '[^0-9]', '', 'g') = '27388490'
    and payment_date::date = date '2026-08-09'
  for update;

  update public.unmatched_payments
  set resolved = true,
      resolved_at = v_resolved_at,
      resolved_by = null,
      updated_at = v_resolved_at
  where id = v_suspense.id;

  update public.mpesa_callback_queue
  set confirmed = true,
      unmatched = false,
      unmatched_reason = 'Excluded from lending: business investment capital',
      updated_at = v_resolved_at
  where trans_id = coalesce(v_suspense.mpesa_reference, v_suspense.invoice_id)
    and trans_amount = 100000
    and (business_id = v_business_id or business_id is null);

  insert into public.loan_audit_log (
    business_id, user_id, action, table_name, record_id, old_value, new_value
  ) values (
    v_business_id,
    null,
    'suspense_excluded_non_loan_investment',
    'unmatched_payments',
    v_suspense.id::text,
    jsonb_build_object(
      'reference', coalesce(v_suspense.mpesa_reference, v_suspense.invoice_id),
      'payer_name', v_suspense.payer_name,
      'account_number', v_suspense.account_number,
      'amount', v_suspense.amount,
      'payment_date', v_suspense.payment_date,
      'resolved', v_suspense.resolved
    ),
    jsonb_build_object(
      'resolved', true,
      'classification', 'business_investment_capital',
      'reason', 'Not a loan repayment or client charge',
      'resolved_at', v_resolved_at
    )
  );
end;
$$;

-- Expected result: one resolved suspense record and no repayment/charge created.
select
  mpesa_reference,
  payer_name,
  account_number,
  amount,
  payment_date,
  resolved,
  resolved_at
from public.unmatched_payments
where business_id = 'BIZ-58D22296'
  and amount = 100000
  and upper(trim(coalesce(payer_name, ''))) like '%SHADRACK%'
  and regexp_replace(coalesce(account_number, ''), '[^0-9]', '', 'g') = '27388490'
  and payment_date::date = date '2026-08-09';
