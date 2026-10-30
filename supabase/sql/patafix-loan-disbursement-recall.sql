-- PataFix controlled disbursement recall.
-- Run once in the PataFix Supabase SQL Editor.

begin;

create table if not exists public.patafix_recalled_repayments (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_id uuid not null,
  client_id uuid not null references public.loan_clients(id) on delete cascade,
  original_repayment_id uuid not null,
  amount numeric(14,2) not null,
  payment_snapshot jsonb not null,
  recalled_by uuid references public.loan_staff(id) on delete set null,
  recall_reason text not null,
  recalled_at timestamptz not null default now(),
  unique (business_id, original_repayment_id)
);

create index if not exists patafix_recalled_repayments_loan_idx
  on public.patafix_recalled_repayments (business_id, loan_id, recalled_at);

alter table public.patafix_recalled_repayments enable row level security;

drop policy if exists patafix_recalled_repayments_select on public.patafix_recalled_repayments;
create policy patafix_recalled_repayments_select
on public.patafix_recalled_repayments for select to authenticated
using (business_id = public.current_patafix_business_id());

grant select on public.patafix_recalled_repayments to authenticated;

create or replace function public.patafix_recall_disbursement(
  p_loan_id uuid,
  p_actual_disbursed_amount numeric,
  p_reason text,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_staff_role text;
  v_loan public.loans%rowtype;
  v_application_id uuid;
  v_application_amount numeric(14,2);
  v_repayment public.loan_repayments%rowtype;
  v_fee public.client_charge_transactions%rowtype;
  v_wallet_transaction_id uuid;
  v_repayment_count integer := 0;
  v_repayment_total numeric(14,2) := 0;
  v_fee_total numeric(14,2) := 0;
  v_schedule_count integer := 0;
  v_penalty_count integer := 0;
  v_wallet_balance numeric(14,2) := 0;
begin
  if v_business_id is null then
    raise exception 'Your PataFix session is not linked to an active business. Please sign in again.';
  end if;

  select id,role into v_staff_id,v_staff_role
  from public.loan_staff
  where business_id=v_business_id
    and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
  order by last_login desc nulls last,created_at desc
  limit 1;

  if v_staff_id is null or not (
    regexp_split_to_array(lower(coalesce(v_staff_role,'')), '\s*,\s*') && array['admin']::text[]
  ) then
    raise exception 'Only an administrator can recall a disbursement.';
  end if;

  if upper(trim(coalesce(p_confirmation,''))) <> 'RECALL' then
    raise exception 'Type RECALL to confirm this action.';
  end if;
  if coalesce(p_actual_disbursed_amount,0)<=0 then
    raise exception 'Enter the actual amount sent to the client.';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then
    raise exception 'Enter a clear reason for recalling this disbursement.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_business_id||':recall:'||p_loan_id::text));

  select * into v_loan
  from public.loans
  where id=p_loan_id and business_id=v_business_id
  for update;

  if not found then raise exception 'Loan not found for this business.'; end if;
  if v_loan.status='recalled' then raise exception 'This disbursement has already been recalled.'; end if;
  if v_loan.status not in ('active','completed','defaulted') then
    raise exception 'Only an active, completed or defaulted loan can be recalled.';
  end if;
  if v_loan.application_id is null then
    raise exception 'This loan is not linked to an application and cannot be reopened automatically.';
  end if;

  v_application_id := v_loan.application_id;
  select applied_amount into v_application_amount
  from public.loan_applications
  where id=v_application_id and business_id=v_business_id
  for update;
  if not found then raise exception 'The linked loan application was not found.'; end if;

  for v_repayment in
    select * from public.loan_repayments
    where loan_id=p_loan_id and business_id=v_business_id
    order by payment_date,created_at
    for update
  loop
    insert into public.patafix_recalled_repayments (
      business_id,loan_id,client_id,original_repayment_id,amount,payment_snapshot,
      recalled_by,recall_reason
    ) values (
      v_business_id,p_loan_id,v_loan.client_id,v_repayment.id,v_repayment.amount,to_jsonb(v_repayment),
      v_staff_id,trim(p_reason)
    ) on conflict (business_id,original_repayment_id) do nothing;

    insert into public.client_charge_transactions (
      business_id,client_id,loan_id,transaction_type,charge_type,amount,transaction_date,
      reference,payment_method,description,source_key,created_by
    ) values (
      v_business_id,v_loan.client_id,p_loan_id,'adjustment_credit','excess',v_repayment.amount,
      v_repayment.payment_date::date,coalesce(v_repayment.payment_reference,v_repayment.receipt_no),
      v_repayment.payment_method,'Repayment returned after recalling loan '||v_loan.loan_no||' | '||trim(p_reason),
      'loan-recall:'||p_loan_id::text||':repayment:'||v_repayment.id::text,v_staff_id
    ) on conflict (business_id,source_key) where source_key is not null do nothing
    returning id into v_wallet_transaction_id;

    v_repayment_count := v_repayment_count+1;
    v_repayment_total := v_repayment_total+v_repayment.amount;
  end loop;

  for v_fee in
    select * from public.client_charge_transactions
    where business_id=v_business_id and loan_id=p_loan_id
      and transaction_type='fee_debit' and charge_type='processing'
    order by transaction_date,created_at
  loop
    insert into public.client_charge_transactions (
      business_id,client_id,loan_id,transaction_type,charge_type,amount,transaction_date,
      reference,payment_method,description,source_key,created_by
    ) values (
      v_business_id,v_loan.client_id,p_loan_id,'adjustment_credit',v_fee.charge_type,v_fee.amount,current_date,
      coalesce(v_fee.reference,'RECALL-'||v_loan.loan_no),v_fee.payment_method,
      'Processing/application fee restored after recalling loan '||v_loan.loan_no||' | '||trim(p_reason),
      'loan-recall:'||p_loan_id::text||':fee:'||v_fee.id::text,v_staff_id
    ) on conflict (business_id,source_key) where source_key is not null do nothing;
    v_fee_total := v_fee_total+v_fee.amount;
  end loop;

  delete from public.loan_repayments
  where loan_id=p_loan_id and business_id=v_business_id;

  update public.loan_schedules
  set status='cancelled',updated_at=now()
  where loan_id=p_loan_id and status<>'restructured';
  get diagnostics v_schedule_count=row_count;

  update public.loan_penalties
  set is_waived=true,waived_reason='Loan disbursement recalled: '||trim(p_reason),
      waived_by=v_staff_id,waived_at=now()
  where loan_id=p_loan_id and business_id=v_business_id and is_waived=false;
  get diagnostics v_penalty_count=row_count;

  update public.loans
  set status='recalled',application_id=null,total_paid=0,outstanding_balance=0,
      arrears_amount=0,overdue_days=0,updated_at=now()
  where id=p_loan_id and business_id=v_business_id;

  update public.loan_applications
  set status='approved',applied_amount=round(p_actual_disbursed_amount,2),updated_at=now(),
      rejection_reason=null
  where id=v_application_id and business_id=v_business_id;

  if v_repayment_total>0 then
    insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
    values (v_business_id,current_date,'RECALL-'||v_loan.loan_no,
      'Repayments returned to Charges & Excess after recalling loan '||v_loan.loan_no||' | '||trim(p_reason),
      'Charges & Excess Account','Loan Repayments',round(v_repayment_total,2),false);
  end if;

  if v_fee_total>0 then
    insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
    values (v_business_id,current_date,'RECALL-FEE-'||v_loan.loan_no,
      'Processing/application fee restored to Charges & Excess after recall | Loan '||v_loan.loan_no||' | '||trim(p_reason),
      'Processing Fee Income','Charges & Excess Account',round(v_fee_total,2),false);
  end if;

  insert into public.loan_audit_log (
    business_id,user_id,action,table_name,record_id,old_value,new_value
  ) values (
    v_business_id,v_staff_id,'loan_disbursement_recalled','loans',p_loan_id::text,
    jsonb_build_object(
      'status',v_loan.status,'application_id',v_application_id,'booked_principal',v_loan.principal_amount,
      'recorded_disbursed_amount',v_loan.disbursed_amount,'application_amount',v_application_amount,
      'total_paid',v_loan.total_paid,'outstanding_balance',v_loan.outstanding_balance,
      'repayment_count',v_repayment_count,'repayments_total',round(v_repayment_total,2)
    ),
    jsonb_build_object(
      'status','recalled','actual_disbursed_amount',round(p_actual_disbursed_amount,2),
      'repayments_recalled',v_repayment_count,'repayments_moved_to_charges',round(v_repayment_total,2),
      'fees_restored',round(v_fee_total,2),'schedules_cancelled',v_schedule_count,
      'penalties_waived',v_penalty_count,'application_status','approved',
      'corrected_application_amount',round(p_actual_disbursed_amount,2),'reason',trim(p_reason)
    )
  );

  insert into public.loan_audit_log (
    business_id,user_id,action,table_name,record_id,old_value,new_value
  ) values (
    v_business_id,v_staff_id,'application_reopened_after_recall','loan_applications',v_application_id::text,
    jsonb_build_object('status','disbursed','applied_amount',v_application_amount,'loan_id',p_loan_id),
    jsonb_build_object('status','approved','applied_amount',round(p_actual_disbursed_amount,2),'reason',trim(p_reason))
  );

  select public.patafix_client_charge_balance(v_loan.client_id) into v_wallet_balance;

  return jsonb_build_object(
    'ok',true,'loan_id',p_loan_id,'loan_no',v_loan.loan_no,'status','recalled',
    'application_id',v_application_id,'application_status','approved',
    'corrected_application_amount',round(p_actual_disbursed_amount,2),
    'repayments_recalled',v_repayment_count,'repayments_moved_to_charges',round(v_repayment_total,2),
    'fees_restored',round(v_fee_total,2),'wallet_balance',v_wallet_balance,
    'schedules_cancelled',v_schedule_count,'penalties_waived',v_penalty_count
  );
end;
$$;

revoke all on function public.patafix_recall_disbursement(uuid,numeric,text,text) from public,anon;
grant execute on function public.patafix_recall_disbursement(uuid,numeric,text,text) to authenticated;

comment on function public.patafix_recall_disbursement(uuid,numeric,text,text)
is 'Admin-only atomic recall: archives repayments, credits them and used fees to Charges & Excess, cancels the mistaken loan schedule, and reopens the corrected application.';

commit;

select 'PataFix disbursement recall ready' as status;
