-- Restore Veronica's contractual weekly schedule after the legacy automatic
-- rollover replaced her unpaid installments with three future-dated rows.
-- This script is deliberately guarded and stops if the verified loan changed.

begin;

do $$
declare
  v_loan public.loans%rowtype;
  v_first_due date;
  v_penalty numeric(14,2);
  v_original_total numeric(14,2);
  v_regular_due numeric(14,2);
  v_regular_principal numeric(14,2);
  v_regular_interest numeric(14,2);
  v_retained_paid numeric(14,2);
  v_payment_carry numeric(14,2);
  v_due numeric(14,2);
  v_principal numeric(14,2);
  v_interest numeric(14,2);
  v_paid numeric(14,2);
  v_generated_count integer;
  v_existing_original_count integer;
  v_i integer;
begin
  select l.*
    into strict v_loan
  from public.loans l
  join public.loan_clients c on c.id = l.client_id
  where l.business_id = 'BIZ-58D22296'
    and l.loan_no = '314185'
    and regexp_replace(coalesce(c.id_number,''),'[^0-9]','','g') = '5763255'
  for update;

  if v_loan.status <> 'active'
     or abs(coalesce(v_loan.total_paid,0) - 6510.00) > 0.01
     or abs(coalesce(v_loan.outstanding_balance,0) - 6814.50) > 0.01
     or v_loan.term_weeks <> 6 then
    raise exception 'Safety check stopped: Veronica loan 314185 has changed. Paid %, balance %, term %.',
      v_loan.total_paid, v_loan.outstanding_balance, v_loan.term_weeks;
  end if;

  select count(*)
    into v_generated_count
  from public.loan_schedules
  where loan_id = v_loan.id
    and installment_no > 100000
    and coalesce(total_paid,0) = 0;

  select count(*)
    into v_existing_original_count
  from public.loan_schedules
  where loan_id = v_loan.id
    and installment_no between 4 and 6;

  if v_generated_count <> 3 or v_existing_original_count <> 0 then
    raise exception 'Safety check stopped: expected 3 legacy rollover rows and no installments 4-6; found % and %.',
      v_generated_count, v_existing_original_count;
  end if;

  select min(due_date), coalesce(sum(total_paid),0)
    into v_first_due, v_retained_paid
  from public.loan_schedules
  where loan_id = v_loan.id
    and installment_no between 1 and 3;

  if v_first_due is null then
    raise exception 'Safety check stopped: original paid installments 1-3 were not found.';
  end if;

  select coalesce(sum(penalty_amount),0)
    into v_penalty
  from public.loan_penalties
  where loan_id = v_loan.id
    and reason ilike 'Rollover Penalty (%'
    and not coalesce(is_waived,false);

  if v_penalty <= 0 then
    raise exception 'Safety check stopped: the rollover penalty was not found.';
  end if;

  v_original_total := round(v_loan.total_payable - v_penalty,2);
  v_regular_due := round(v_original_total / v_loan.term_weeks,2);
  v_regular_principal := round(v_loan.principal_amount / v_loan.term_weeks,2);
  v_regular_interest := round(v_loan.total_interest / v_loan.term_weeks,2);
  v_payment_carry := greatest(0,round(v_loan.total_paid - v_retained_paid,2));

  delete from public.loan_schedules
  where loan_id = v_loan.id
    and installment_no > 100000
    and coalesce(total_paid,0) = 0;

  for v_i in 4..6 loop
    v_principal := case when v_i < 6 then v_regular_principal
      else round(v_loan.principal_amount - (v_regular_principal * 5),2) end;
    v_interest := case when v_i < 6 then v_regular_interest
      else round(v_loan.total_interest - (v_regular_interest * 5),2) end;
    v_due := round(v_principal + v_interest + case when v_i = 6 then v_penalty else 0 end,2);
    v_paid := least(v_payment_carry,v_due);
    v_payment_carry := round(v_payment_carry-v_paid,2);

    insert into public.loan_schedules (
      business_id,branch_name,loan_id,installment_no,due_date,
      principal_due,interest_due,total_due,principal_paid,interest_paid,
      total_paid,penalty_charged,status,paid_at
    ) values (
      v_loan.business_id,coalesce(v_loan.branch_name,'Head Office'),v_loan.id,v_i,
      v_first_due + ((v_i-1)*7),v_principal,v_interest,v_due,
      least(v_paid,v_principal),greatest(0,v_paid-v_principal),v_paid,
      case when v_i=6 then v_penalty else 0 end,
      case when v_paid >= v_due then 'paid'
           when v_first_due + ((v_i-1)*7) < current_date then 'overdue'
           when v_paid > 0 then 'partial' else 'pending' end,
      case when v_paid >= v_due then now() else null end
    );
  end loop;

  update public.loans
  set first_repayment_date = v_first_due,
      maturity_date = v_first_due + ((term_weeks-1)*7),
      weekly_installment = v_regular_due,
      arrears_amount = outstanding_balance,
      overdue_days = greatest(0,current_date-(v_first_due+(3*7))),
      updated_at = now()
  where id = v_loan.id;

  insert into public.loan_audit_log (
    business_id,user_id,action,table_name,record_id,new_value
  ) values (
    v_loan.business_id,null,'loan_schedule_gap_repaired','loans',v_loan.id::text,
    jsonb_build_object(
      'loan_no',v_loan.loan_no,
      'restored_installments',jsonb_build_array(4,5,6),
      'first_repayment_date',v_first_due,
      'maturity_date',v_first_due+((v_loan.term_weeks-1)*7),
      'rollover_penalty_preserved',v_penalty,
      'reason','Restored original weekly due dates removed by legacy automatic rollover'
    )
  );
end $$;

commit;

select
  c.full_name as client,
  l.loan_no,
  l.first_repayment_date,
  l.maturity_date,
  l.total_payable,
  l.total_paid,
  l.outstanding_balance,
  l.arrears_amount,
  l.overdue_days,
  s.installment_no,
  s.due_date,
  s.total_due,
  s.total_paid,
  round(greatest(s.total_due-s.total_paid,0),2) as remaining,
  s.penalty_charged,
  s.status
from public.loans l
join public.loan_clients c on c.id=l.client_id
join public.loan_schedules s on s.loan_id=l.id
where l.business_id='BIZ-58D22296'
  and l.loan_no='314185'
order by s.due_date,s.installment_no;
