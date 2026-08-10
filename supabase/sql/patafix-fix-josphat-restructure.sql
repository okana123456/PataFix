-- One-time repair for Josphat Muthusi Ngunanga, loan 446939.
-- This script stops with an error if the loan has changed since diagnosis.

do $$
declare
  v_loan public.loans%rowtype;
  v_payment public.loan_repayments%rowtype;
  v_client_name text;
  v_repayment_count integer;
  v_repayment_total numeric(14,2);
  v_schedule_count integer;
  v_schedule_paid numeric(14,2);
begin
  select l, c.full_name
  into v_loan, v_client_name
  from public.loans l
  join public.loan_clients c on c.id = l.client_id
  where l.business_id = 'BIZ-58D22296'
    and l.loan_no = '446939'
    and c.full_name ilike '%josphat%'
    and c.full_name ilike '%muthusi%'
  limit 1
  for update of l;

  if not found then
    raise exception 'Josphat loan 446939 was not found.';
  end if;

  if v_loan.total_payable = 16250
     and v_loan.total_interest = 3250
     and v_loan.weekly_installment = 3250
     and v_loan.outstanding_balance = 13000 then
    raise notice 'Josphat loan 446939 is already repaired.';
    return;
  end if;

  if v_loan.principal_amount <> 13000
     or v_loan.term_weeks <> 5
     or v_loan.total_payable <> 16900
     or v_loan.total_paid <> 3250
     or v_loan.outstanding_balance <> 13650 then
    raise exception 'Safety check stopped the repair because the loan figures have changed. Current loan: %', row_to_json(v_loan);
  end if;

  select count(*), coalesce(sum(amount), 0)
  into v_repayment_count, v_repayment_total
  from public.loan_repayments
  where loan_id = v_loan.id;

  if v_repayment_count <> 1 or v_repayment_total <> 3250 then
    raise exception 'Safety check stopped the repair because repayments have changed. Count: %, total: %', v_repayment_count, v_repayment_total;
  end if;

  select *
  into v_payment
  from public.loan_repayments
  where loan_id = v_loan.id
    and receipt_no = 'UHA6Y276DO'
    and amount = 3250
  limit 1
  for update;

  if not found then
    raise exception 'Expected repayment UHA6Y276DO for KES 3,250 was not found.';
  end if;

  select count(*), coalesce(sum(total_paid), 0)
  into v_schedule_count, v_schedule_paid
  from public.loan_schedules
  where loan_id = v_loan.id
    and installment_no between 7 and 11;

  if v_schedule_count <> 5 or v_schedule_paid <> 3250 then
    raise exception 'Safety check stopped the repair because the restructured schedule has changed. Rows: %, paid: %', v_schedule_count, v_schedule_paid;
  end if;

  update public.loan_repayments
  set principal_portion = 2600,
      interest_portion = 650,
      penalty_portion = 0,
      updated_at = now()
  where id = v_payment.id;

  update public.loan_schedules
  set principal_due = 2600,
      interest_due = 650,
      total_due = 3250,
      principal_paid = case when installment_no = 7 then 2600 else 0 end,
      interest_paid = case when installment_no = 7 then 650 else 0 end,
      total_paid = case when installment_no = 7 then 3250 else 0 end,
      penalty_charged = 0,
      status = case when installment_no = 7 then 'paid' else 'pending' end,
      paid_at = case when installment_no = 7 then v_payment.payment_date else null end,
      updated_at = now()
  where loan_id = v_loan.id
    and installment_no between 7 and 11;

  update public.loans
  set total_interest = 3250,
      total_payable = 16250,
      weekly_installment = 3250,
      total_paid = 3250,
      outstanding_balance = 13000,
      arrears_amount = 0,
      overdue_days = 0,
      first_repayment_date = date '2026-08-10',
      maturity_date = date '2026-09-07',
      updated_at = now()
  where id = v_loan.id;

  insert into public.loan_audit_log (
    business_id, user_id, action, table_name, record_id, old_value, new_value
  ) values (
    v_loan.business_id,
    null,
    'loan_restructure_math_repaired',
    'loans',
    v_loan.id::text,
    jsonb_build_object(
      'total_interest', v_loan.total_interest,
      'total_payable', v_loan.total_payable,
      'weekly_installment', v_loan.weekly_installment,
      'total_paid', v_loan.total_paid,
      'outstanding_balance', v_loan.outstanding_balance,
      'payment_principal_portion', v_payment.principal_portion,
      'payment_interest_portion', v_payment.interest_portion
    ),
    jsonb_build_object(
      'reason', 'Corrected restructuring to recalculate 5-week interest',
      'total_interest', 3250,
      'total_payable', 16250,
      'weekly_installment', 3250,
      'total_paid', 3250,
      'outstanding_balance', 13000,
      'payment_principal_portion', 2600,
      'payment_interest_portion', 650
    )
  );
end;
$$;

select
  l.loan_no,
  c.full_name as client,
  l.principal_amount,
  l.total_interest,
  l.total_payable,
  l.weekly_installment,
  l.total_paid,
  l.outstanding_balance,
  l.first_repayment_date,
  l.maturity_date,
  jsonb_agg(
    jsonb_build_object(
      'installment', s.installment_no,
      'due_date', s.due_date,
      'principal_due', s.principal_due,
      'interest_due', s.interest_due,
      'total_due', s.total_due,
      'total_paid', s.total_paid,
      'remaining', greatest(0, s.total_due - s.total_paid),
      'status', s.status
    ) order by s.installment_no
  ) filter (where s.installment_no between 7 and 11) as corrected_schedule
from public.loans l
join public.loan_clients c on c.id = l.client_id
left join public.loan_schedules s on s.loan_id = l.id
where l.business_id = 'BIZ-58D22296'
  and l.loan_no = '446939'
  and c.full_name ilike '%josphat%'
  and c.full_name ilike '%muthusi%'
group by l.id, c.full_name;
