-- PataFix loan restructuring
-- Run this file once in Supabase SQL Editor before using the Restructure action.

create or replace function public.patafix_restructure_loan(
  p_loan_id uuid,
  p_term_weeks integer,
  p_first_due_date date,
  p_interval_weeks integer,
  p_reason text
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_staff_role text;
  v_loan public.loans%rowtype;
  v_installments integer;
  v_existing_interval_weeks integer := 1;
  v_next_installment integer;
  v_archived_count integer;
  v_maturity_date date;
  v_regular_amount numeric(14,2);
  v_total_due numeric(14,2);
  v_principal_due numeric(14,2);
  v_interest_due numeric(14,2);
  v_penalty_due numeric(14,2);
  v_paid_principal numeric(14,2) := 0;
  v_paid_interest numeric(14,2) := 0;
  v_paid_penalty numeric(14,2) := 0;
  v_repayments_total numeric(14,2) := 0;
  v_allocated_total numeric(14,2) := 0;
  v_unallocated_paid numeric(14,2) := 0;
  v_original_principal_ratio numeric := 1;
  v_remaining_principal numeric(14,2) := 0;
  v_remaining_penalty numeric(14,2) := 0;
  v_new_interest numeric(14,2) := 0;
  v_new_outstanding numeric(14,2) := 0;
  v_weekly_rate numeric := 0;
  v_new_period_rate numeric := 0;
  v_inserted_total numeric(14,2) := 0;
  v_inserted_principal numeric(14,2) := 0;
  v_inserted_interest numeric(14,2) := 0;
  v_inserted_penalty numeric(14,2) := 0;
  v_due_date date;
  i integer;
begin
  if v_business_id is null then
    raise exception 'Your PataFix session is not linked to an active business. Please sign in again.';
  end if;

  select id, role
    into v_staff_id, v_staff_role
  from public.loan_staff
  where auth_user_id = auth.uid()
    and business_id = v_business_id
    and is_active = true
  limit 1;

  if v_staff_id is null or not (
    regexp_split_to_array(lower(coalesce(v_staff_role, '')), '\s*,\s*')
      && array['admin','branch_manager']::text[]
  ) then
    raise exception 'Only an administrator or manager can restructure a loan.';
  end if;

  if p_term_weeks is null or p_term_weeks < 1 or p_term_weeks > 260 then
    raise exception 'The remaining term must be between 1 and 260 weeks.';
  end if;

  if p_interval_weeks is null or p_interval_weeks not in (1, 2) then
    raise exception 'Repayment frequency must be weekly or biweekly.';
  end if;

  if p_first_due_date is null or p_first_due_date < current_date then
    raise exception 'The first restructured repayment date cannot be in the past.';
  end if;

  if length(trim(coalesce(p_reason, ''))) < 3 then
    raise exception 'Enter a reason for restructuring the loan.';
  end if;

  select *
    into v_loan
  from public.loans
  where id = p_loan_id
    and business_id = v_business_id
  for update;

  if not found then
    raise exception 'Loan not found for this business.';
  end if;

  if v_loan.status <> 'active' or v_loan.outstanding_balance <= 0 then
    raise exception 'Only an active loan with an outstanding balance can be restructured.';
  end if;

  v_installments := ceil(p_term_weeks::numeric / p_interval_weeks)::integer;
  v_maturity_date := p_first_due_date + ((v_installments - 1) * p_interval_weeks * 7);

  select case
    when count(*) >= 2 then greatest(
      1,
      least(2, round((max(due_date) - min(due_date)) / 7.0)::integer)
    )
    else 1
  end
  into v_existing_interval_weeks
  from (
    select due_date
    from public.loan_schedules
    where loan_id = p_loan_id
      and installment_no > coalesce((
        select max(archived.installment_no)
        from public.loan_schedules archived
        where archived.loan_id = p_loan_id
          and archived.status = 'restructured'
      ), 0)
    order by due_date, installment_no
    limit 2
  ) current_schedule_dates;

  v_weekly_rate := case
    when v_existing_interval_weeks > 0 then v_loan.interest_rate / v_existing_interval_weeks
    else v_loan.interest_rate
  end;
  v_new_period_rate := round(v_weekly_rate * p_interval_weeks, 4);

  select
    coalesce(sum(principal_portion), 0),
    coalesce(sum(interest_portion), 0),
    coalesce(sum(penalty_portion), 0),
    coalesce(sum(amount), 0)
  into v_paid_principal, v_paid_interest, v_paid_penalty, v_repayments_total
  from public.loan_repayments
  where loan_id = p_loan_id
    and business_id = v_business_id;

  -- Older imported repayments can have zero allocation columns. Allocate only
  -- their missing portion using the original principal/interest proportions.
  v_allocated_total := v_paid_principal + v_paid_interest + v_paid_penalty;
  v_unallocated_paid := greatest(
    0,
    greatest(v_repayments_total, v_loan.total_paid) - v_allocated_total
  );
  v_original_principal_ratio := case
    when v_loan.total_payable > 0
      then greatest(0, least(1, v_loan.principal_amount / v_loan.total_payable))
    else 1
  end;
  v_paid_principal := least(
    v_loan.principal_amount,
    v_paid_principal + round(v_unallocated_paid * v_original_principal_ratio, 2)
  );
  v_paid_interest := v_paid_interest + greatest(
    0,
    v_unallocated_paid - round(v_unallocated_paid * v_original_principal_ratio, 2)
  );

  v_remaining_principal := greatest(0, v_loan.principal_amount - v_paid_principal);

  select greatest(0, coalesce(sum(penalty_amount), 0) - v_paid_penalty)
  into v_remaining_penalty
  from public.loan_penalties
  where loan_id = p_loan_id
    and business_id = v_business_id
    and is_waived = false;

  -- interest_rate is stored per repayment period: weekly loans use the weekly
  -- rate and biweekly loans use the biweekly rate.
  v_new_interest := round(
    v_remaining_principal * (v_new_period_rate / 100) * v_installments,
    2
  );
  v_new_outstanding := round(
    v_remaining_principal + v_new_interest + v_remaining_penalty,
    2
  );
  if v_new_outstanding <= 0 then
    raise exception 'This loan has no principal, interest or penalty balance to restructure.';
  end if;
  v_regular_amount := round(v_new_outstanding / v_installments, 2);

  select coalesce(max(installment_no), 0) + 1
    into v_next_installment
  from public.loan_schedules
  where loan_id = p_loan_id;

  update public.loan_schedules
  set status = 'restructured', updated_at = now()
  where loan_id = p_loan_id
    and status in ('pending', 'partial', 'overdue');
  get diagnostics v_archived_count = row_count;

  for i in 1..v_installments loop
    v_due_date := p_first_due_date + ((i - 1) * p_interval_weeks * 7);
    if i = v_installments then
      v_principal_due := round(v_remaining_principal - v_inserted_principal, 2);
      v_interest_due := round(v_new_interest - v_inserted_interest, 2);
      v_penalty_due := round(v_remaining_penalty - v_inserted_penalty, 2);
    else
      v_principal_due := round(v_remaining_principal / v_installments, 2);
      v_interest_due := round(v_new_interest / v_installments, 2);
      v_penalty_due := round(v_remaining_penalty / v_installments, 2);
    end if;
    v_total_due := round(v_principal_due + v_interest_due + v_penalty_due, 2);

    insert into public.loan_schedules (
      business_id, loan_id, installment_no, due_date,
      principal_due, interest_due, total_due,
      principal_paid, interest_paid, total_paid,
      penalty_charged, status
    ) values (
      v_business_id, p_loan_id, v_next_installment + i - 1, v_due_date,
      v_principal_due, v_interest_due, v_total_due,
      0, 0, 0,
      v_penalty_due, 'pending'
    );

    v_inserted_total := v_inserted_total + v_total_due;
    v_inserted_principal := v_inserted_principal + v_principal_due;
    v_inserted_interest := v_inserted_interest + v_interest_due;
    v_inserted_penalty := v_inserted_penalty + v_penalty_due;
  end loop;

  update public.loans
  set term_weeks = p_term_weeks,
      first_repayment_date = p_first_due_date,
      maturity_date = v_maturity_date,
      weekly_installment = v_regular_amount,
      interest_rate = v_new_period_rate,
      total_interest = round(v_paid_interest + v_new_interest, 2),
      total_payable = round(v_loan.total_paid + v_new_outstanding, 2),
      outstanding_balance = v_new_outstanding,
      arrears_amount = 0,
      overdue_days = 0,
      updated_at = now()
  where id = p_loan_id
    and business_id = v_business_id;

  insert into public.loan_audit_log (
    business_id, user_id, action, table_name, record_id, old_value, new_value
  ) values (
    v_business_id,
    v_staff_id,
    'loan_restructured',
    'loans',
    p_loan_id::text,
    jsonb_build_object(
      'term_weeks', v_loan.term_weeks,
      'first_repayment_date', v_loan.first_repayment_date,
      'maturity_date', v_loan.maturity_date,
      'weekly_installment', v_loan.weekly_installment,
      'interest_rate_per_period', v_loan.interest_rate,
      'total_interest', v_loan.total_interest,
      'total_payable', v_loan.total_payable,
      'outstanding_balance', v_loan.outstanding_balance,
      'arrears_amount', v_loan.arrears_amount,
      'overdue_days', v_loan.overdue_days
    ),
    jsonb_build_object(
      'term_weeks', p_term_weeks,
      'repayment_interval_weeks', p_interval_weeks,
      'installments', v_installments,
      'first_repayment_date', p_first_due_date,
      'maturity_date', v_maturity_date,
      'installment_amount', v_regular_amount,
      'remaining_principal', v_remaining_principal,
      'recalculated_interest', v_new_interest,
      'interest_rate_per_period', v_new_period_rate,
      'remaining_penalty', v_remaining_penalty,
      'outstanding_balance', v_new_outstanding,
      'total_interest', round(v_paid_interest + v_new_interest, 2),
      'total_payable', round(v_loan.total_paid + v_new_outstanding, 2),
      'reason', trim(p_reason),
      'archived_schedules', v_archived_count
    )
  );

  return jsonb_build_object(
    'ok', true,
    'loan_id', p_loan_id,
    'loan_no', v_loan.loan_no,
    'remaining_principal', v_remaining_principal,
    'recalculated_interest', v_new_interest,
    'interest_rate_per_period', v_new_period_rate,
    'remaining_penalty', v_remaining_penalty,
    'remaining_balance', v_new_outstanding,
    'term_weeks', p_term_weeks,
    'repayment_interval_weeks', p_interval_weeks,
    'installments', v_installments,
    'installment_amount', v_regular_amount,
    'first_due_date', p_first_due_date,
    'maturity_date', v_maturity_date,
    'archived_schedules', v_archived_count
  );
end;
$$;

revoke all on function public.patafix_restructure_loan(uuid, integer, date, integer, text) from public, anon;
grant execute on function public.patafix_restructure_loan(uuid, integer, date, integer, text) to authenticated;

comment on function public.patafix_restructure_loan(uuid, integer, date, integer, text)
is 'Archives the unpaid schedule, preserves prior payments, and recalculates interest from remaining principal using the new term.';
