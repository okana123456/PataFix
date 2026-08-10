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
  v_next_installment integer;
  v_archived_count integer;
  v_maturity_date date;
  v_regular_amount numeric(14,2);
  v_total_due numeric(14,2);
  v_principal_due numeric(14,2);
  v_interest_due numeric(14,2);
  v_interest_ratio numeric;
  v_inserted_total numeric(14,2) := 0;
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
  v_regular_amount := round(v_loan.outstanding_balance / v_installments, 2);
  v_interest_ratio := case
    when v_loan.total_payable > 0 then greatest(0, least(1, v_loan.total_interest / v_loan.total_payable))
    else 0
  end;

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
    v_total_due := case
      when i = v_installments then round(v_loan.outstanding_balance - v_inserted_total, 2)
      else v_regular_amount
    end;
    v_interest_due := round(v_total_due * v_interest_ratio, 2);
    v_principal_due := round(v_total_due - v_interest_due, 2);

    insert into public.loan_schedules (
      business_id, loan_id, installment_no, due_date,
      principal_due, interest_due, total_due,
      principal_paid, interest_paid, total_paid,
      penalty_charged, status
    ) values (
      v_business_id, p_loan_id, v_next_installment + i - 1, v_due_date,
      v_principal_due, v_interest_due, v_total_due,
      0, 0, 0,
      0, 'pending'
    );

    v_inserted_total := v_inserted_total + v_total_due;
  end loop;

  update public.loans
  set term_weeks = p_term_weeks,
      first_repayment_date = p_first_due_date,
      maturity_date = v_maturity_date,
      weekly_installment = v_regular_amount,
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
      'outstanding_balance', v_loan.outstanding_balance,
      'reason', trim(p_reason),
      'archived_schedules', v_archived_count
    )
  );

  return jsonb_build_object(
    'ok', true,
    'loan_id', p_loan_id,
    'loan_no', v_loan.loan_no,
    'remaining_balance', v_loan.outstanding_balance,
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
is 'Archives the unpaid schedule and redistributes the current outstanding balance without changing prior repayments or adding interest.';
