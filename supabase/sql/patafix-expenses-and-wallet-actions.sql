-- PataFix expenses, finance permissions, refunds and wallet transfers
-- Run once in the PataFix Supabase SQL Editor before deploying the updated index.html.

create extension if not exists pgcrypto;

alter table public.loan_staff
  add column if not exists permissions jsonb not null default '{}'::jsonb;

-- Existing managers can initiate and view expenses, but accounting, approvals and
-- wallet adjustments remain administrator-only until explicitly granted.
update public.loan_staff
set permissions = case
  when regexp_split_to_array(lower(coalesce(role,'')), '\s*,\s*') && array['admin']::text[] then
    '{"view_accounting":true,"view_expenses":true,"create_expenses":true,"approve_expenses":true,"manage_charge_adjustments":true}'::jsonb
  when regexp_split_to_array(lower(coalesce(role,'')), '\s*,\s*') && array['branch_manager']::text[] then
    '{"view_accounting":false,"view_expenses":true,"create_expenses":true,"approve_expenses":false,"manage_charge_adjustments":false}'::jsonb
  else '{}'::jsonb
end || permissions;

create or replace function public.patafix_has_permission(
  p_permission text,
  p_default_roles text[] default array['admin']::text[]
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_permissions jsonb;
  v_roles text[];
begin
  select role, permissions
    into v_role, v_permissions
  from public.loan_staff
  where is_active = true
    and business_id = public.current_patafix_business_id()
    and (
      auth_user_id = auth.uid()
      or lower(trim(email)) = lower(trim(coalesce(auth.jwt() ->> 'email','')))
    )
  order by last_login desc nulls last, created_at desc
  limit 1;

  v_roles := regexp_split_to_array(lower(coalesce(v_role,'')), '\s*,\s*');
  if v_roles && array['admin']::text[] then return true; end if;
  if coalesce(v_permissions,'{}'::jsonb) ? p_permission then
    return coalesce((v_permissions ->> p_permission)::boolean,false);
  end if;
  return v_roles && coalesce(p_default_roles,array[]::text[]);
end;
$$;

revoke all on function public.patafix_has_permission(text,text[]) from public;
grant execute on function public.patafix_has_permission(text,text[]) to authenticated, service_role;

create table if not exists public.patafix_expenses (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  expense_no text not null,
  expense_date date not null default current_date,
  category text not null,
  description text not null,
  amount numeric(14,2) not null check (amount > 0),
  payment_method text not null default 'cash',
  payment_reference text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_by uuid references public.loan_staff(id) on delete set null,
  approved_by uuid references public.loan_staff(id) on delete set null,
  approved_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, expense_no)
);

create index if not exists patafix_expenses_business_date_idx
  on public.patafix_expenses (business_id, expense_date desc, created_at desc);
create index if not exists patafix_expenses_status_idx
  on public.patafix_expenses (business_id, status, expense_date desc);

drop trigger if exists patafix_expenses_updated_at on public.patafix_expenses;
create trigger patafix_expenses_updated_at before update on public.patafix_expenses
for each row execute function public.set_updated_at();

alter table public.patafix_expenses enable row level security;
drop policy if exists patafix_expenses_select on public.patafix_expenses;
create policy patafix_expenses_select on public.patafix_expenses for select to authenticated
using (
  public.patafix_can_access_business(business_id)
  and (
    public.patafix_has_permission('view_expenses',array['admin']::text[])
    or public.patafix_has_permission('view_accounting',array['admin']::text[])
  )
);

revoke insert, update, delete on public.patafix_expenses from anon, authenticated;
grant select on public.patafix_expenses to authenticated;
grant all on public.patafix_expenses to service_role;

create or replace function public.patafix_create_expense(
  p_expense_date date,
  p_category text,
  p_description text,
  p_amount numeric,
  p_payment_method text default 'cash',
  p_payment_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_expense public.patafix_expenses%rowtype;
  v_expense_no text;
begin
  if v_business_id is null then raise exception 'No active PataFix staff account was found.'; end if;
  if not public.patafix_has_permission('create_expenses',array['admin','branch_manager']::text[]) then
    raise exception 'You do not have permission to initiate expenses.';
  end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Expense amount must be greater than zero.'; end if;
  if nullif(trim(coalesce(p_category,'')),'') is null then raise exception 'Select an expense category.'; end if;
  if nullif(trim(coalesce(p_description,'')),'') is null then raise exception 'Enter the expense description.'; end if;

  select id into v_staff_id from public.loan_staff
  where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
  order by last_login desc nulls last, created_at desc limit 1;

  v_expense_no := 'EXP-' || to_char(coalesce(p_expense_date,current_date),'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  insert into public.patafix_expenses (
    business_id,expense_no,expense_date,category,description,amount,
    payment_method,payment_reference,requested_by
  ) values (
    v_business_id,v_expense_no,coalesce(p_expense_date,current_date),trim(p_category),trim(p_description),round(p_amount,2),
    lower(coalesce(nullif(trim(p_payment_method),''),'cash')),nullif(trim(p_payment_reference),''),v_staff_id
  ) returning * into v_expense;

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,new_value)
  values (v_business_id,v_staff_id,'expense_initiated','patafix_expenses',v_expense.id::text,to_jsonb(v_expense));
  return to_jsonb(v_expense);
end;
$$;

create or replace function public.patafix_decide_expense(
  p_expense_id uuid,
  p_decision text,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_expense public.patafix_expenses%rowtype;
  v_decision text := lower(trim(coalesce(p_decision,'')));
  v_cash_account text;
begin
  if not public.patafix_has_permission('approve_expenses',array['admin']::text[]) then
    raise exception 'You do not have permission to approve or reject expenses.';
  end if;
  if v_decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected.'; end if;
  if v_decision='rejected' and nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'Enter the rejection reason.';
  end if;

  select * into v_expense from public.patafix_expenses
  where id=p_expense_id and business_id=v_business_id for update;
  if v_expense.id is null then raise exception 'Expense request was not found.'; end if;
  if v_expense.status <> 'pending' then raise exception 'This expense has already been decided.'; end if;

  select id into v_staff_id from public.loan_staff
  where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
  order by last_login desc nulls last, created_at desc limit 1;

  update public.patafix_expenses set
    status=v_decision, approved_by=v_staff_id, approved_at=now(),
    rejection_reason=case when v_decision='rejected' then trim(p_reason) else null end
  where id=p_expense_id returning * into v_expense;

  if v_decision='approved' then
    v_cash_account := case v_expense.payment_method
      when 'mpesa' then 'M-Pesa'
      when 'bank' then 'Bank'
      when 'imprest' then 'Imprest'
      else 'Cash'
    end;
    insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
    values (
      v_business_id,v_expense.expense_date,coalesce(v_expense.payment_reference,v_expense.expense_no),
      'Approved expense - '||v_expense.category||' | '||v_expense.description,
      'Expense - '||v_expense.category,v_cash_account,v_expense.amount,false
    );
  end if;

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,old_value,new_value)
  values (v_business_id,v_staff_id,'expense_'||v_decision,'patafix_expenses',v_expense.id::text,
    jsonb_build_object('status','pending'),to_jsonb(v_expense));
  return to_jsonb(v_expense);
end;
$$;

alter table public.client_charge_transactions
  drop constraint if exists client_charge_transactions_transaction_type_check;
alter table public.client_charge_transactions
  add constraint client_charge_transactions_transaction_type_check check (
    transaction_type in (
      'deposit','excess_deposit','fee_debit','adjustment_credit','adjustment_debit',
      'refund_debit','transfer_out','transfer_in','loan_transfer_debit'
    )
  );

create or replace function public.patafix_client_charge_balance(p_client_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(
    case
      when transaction_type in ('deposit','excess_deposit','adjustment_credit','transfer_in') then amount
      else -amount
    end
  ),0)::numeric(14,2)
  from public.client_charge_transactions
  where business_id = public.current_patafix_business_id()
    and client_id = p_client_id;
$$;

create or replace function public.patafix_refund_client_charge(
  p_client_id uuid,
  p_amount numeric,
  p_transaction_date date,
  p_reference text,
  p_payment_method text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_balance numeric(14,2);
  v_transaction_id uuid;
  v_ref text;
  v_credit_account text;
begin
  if not public.patafix_has_permission('manage_charge_adjustments',array['admin']::text[]) then
    raise exception 'You do not have permission to refund client balances.';
  end if;
  if coalesce(p_amount,0)<=0 then raise exception 'Refund amount must be greater than zero.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter the refund reason.'; end if;
  if not exists(select 1 from public.loan_clients where id=p_client_id and business_id=v_business_id) then
    raise exception 'Client does not belong to this business.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_business_id||':'||p_client_id::text));
  select public.patafix_client_charge_balance(p_client_id) into v_balance;
  if round(p_amount,2)>v_balance then raise exception 'Refund exceeds the available client balance of KES %.',v_balance; end if;
  select id into v_staff_id from public.loan_staff where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
    order by last_login desc nulls last,created_at desc limit 1;
  v_ref := coalesce(nullif(trim(p_reference),''),'REF-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));

  insert into public.client_charge_transactions (
    business_id,client_id,transaction_type,charge_type,amount,transaction_date,
    reference,payment_method,description,source_key,created_by
  ) values (
    v_business_id,p_client_id,'refund_debit','other',round(p_amount,2),coalesce(p_transaction_date,current_date),
    v_ref,lower(coalesce(nullif(trim(p_payment_method),''),'cash')),'Refund/reversal: '||trim(p_reason),
    'refund:'||gen_random_uuid()::text,v_staff_id
  ) returning id into v_transaction_id;

  v_credit_account := case lower(coalesce(p_payment_method,'cash')) when 'mpesa' then 'M-Pesa' when 'bank' then 'Bank' else 'Cash' end;
  insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
  values (v_business_id,coalesce(p_transaction_date,current_date),v_ref,'Client charge balance refund | '||trim(p_reason),
    'Charges & Excess Account',v_credit_account,round(p_amount,2),false);
  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,new_value)
  values (v_business_id,v_staff_id,'client_charge_refunded','client_charge_transactions',v_transaction_id::text,
    jsonb_build_object('client_id',p_client_id,'amount',round(p_amount,2),'reference',v_ref,'reason',trim(p_reason)));
  select public.patafix_client_charge_balance(p_client_id) into v_balance;
  return jsonb_build_object('ok',true,'transaction_id',v_transaction_id,'balance',v_balance,'reference',v_ref);
end;
$$;

create or replace function public.patafix_transfer_client_charge(
  p_from_client_id uuid,
  p_to_client_id uuid,
  p_amount numeric,
  p_transaction_date date,
  p_reference text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_balance numeric(14,2);
  v_to_balance numeric(14,2);
  v_ref text;
  v_transfer_id uuid := gen_random_uuid();
begin
  if not public.patafix_has_permission('manage_charge_adjustments',array['admin']::text[]) then
    raise exception 'You do not have permission to transfer client balances.';
  end if;
  if p_from_client_id=p_to_client_id then raise exception 'Select a different receiving client.'; end if;
  if coalesce(p_amount,0)<=0 then raise exception 'Transfer amount must be greater than zero.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter the transfer reason.'; end if;
  if not exists(select 1 from public.loan_clients where id=p_from_client_id and business_id=v_business_id) or
     not exists(select 1 from public.loan_clients where id=p_to_client_id and business_id=v_business_id) then
    raise exception 'Both clients must belong to this business.';
  end if;

  perform pg_advisory_xact_lock(least(hashtext(v_business_id||':'||p_from_client_id::text),hashtext(v_business_id||':'||p_to_client_id::text)));
  perform pg_advisory_xact_lock(greatest(hashtext(v_business_id||':'||p_from_client_id::text),hashtext(v_business_id||':'||p_to_client_id::text)));
  select public.patafix_client_charge_balance(p_from_client_id) into v_balance;
  if round(p_amount,2)>v_balance then raise exception 'Transfer exceeds the available client balance of KES %.',v_balance; end if;
  select id into v_staff_id from public.loan_staff where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
    order by last_login desc nulls last,created_at desc limit 1;
  v_ref := coalesce(nullif(trim(p_reference),''),'TRF-'||upper(substr(replace(v_transfer_id::text,'-',''),1,8)));

  insert into public.client_charge_transactions (
    business_id,client_id,transaction_type,charge_type,amount,transaction_date,reference,description,source_key,created_by
  ) values
    (v_business_id,p_from_client_id,'transfer_out','other',round(p_amount,2),coalesce(p_transaction_date,current_date),v_ref,
      'Transfer to another client charges account: '||trim(p_reason),'transfer:'||v_transfer_id::text||':out',v_staff_id),
    (v_business_id,p_to_client_id,'transfer_in','other',round(p_amount,2),coalesce(p_transaction_date,current_date),v_ref,
      'Transfer received from another client charges account: '||trim(p_reason),'transfer:'||v_transfer_id::text||':in',v_staff_id);
  insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
  values (v_business_id,coalesce(p_transaction_date,current_date),v_ref,'Client-to-client Charges Account transfer | '||trim(p_reason),
    'Charges & Excess Account - Receiving Client','Charges & Excess Account - Sending Client',round(p_amount,2),false);
  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,new_value)
  values (v_business_id,v_staff_id,'client_charge_transferred','client_charge_transactions',v_transfer_id::text,
    jsonb_build_object('from_client_id',p_from_client_id,'to_client_id',p_to_client_id,'amount',round(p_amount,2),'reference',v_ref,'reason',trim(p_reason)));
  select public.patafix_client_charge_balance(p_from_client_id) into v_balance;
  select public.patafix_client_charge_balance(p_to_client_id) into v_to_balance;
  return jsonb_build_object('ok',true,'from_balance',v_balance,'to_balance',v_to_balance,'reference',v_ref);
end;
$$;

create or replace function public.patafix_transfer_charge_to_loan(
  p_from_client_id uuid,
  p_loan_id uuid,
  p_amount numeric,
  p_transaction_date date,
  p_reference text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_loan public.loans%rowtype;
  v_balance numeric(14,2);
  v_ref text;
  v_receipt text;
  v_payment_ts timestamptz;
  v_interest_remaining numeric := 0;
  v_principal_remaining numeric := 0;
  v_interest_ratio numeric := 0;
  v_interest_portion numeric := 0;
  v_principal_portion numeric := 0;
  v_remaining numeric;
  v_apply numeric;
  v_new_total numeric;
  v_new_balance numeric;
  v_arrears numeric := 0;
  v_oldest_due date;
  v_overdue_days integer := 0;
  v_repayment_id uuid;
  v_schedule record;
  v_schedule_principal_remaining numeric;
  v_schedule_interest_remaining numeric;
  v_schedule_principal_apply numeric;
  v_schedule_interest_apply numeric;
begin
  if not public.patafix_has_permission('manage_charge_adjustments',array['admin']::text[]) then
    raise exception 'You do not have permission to transfer client balances.';
  end if;
  if coalesce(p_amount,0)<=0 then raise exception 'Transfer amount must be greater than zero.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter the transfer reason.'; end if;

  select * into v_loan from public.loans where id=p_loan_id and business_id=v_business_id for update;
  if v_loan.id is null then raise exception 'Receiving loan was not found.'; end if;
  if v_loan.status<>'active' or v_loan.outstanding_balance<=0 then raise exception 'The selected loan is not active.'; end if;
  if not exists(select 1 from public.loan_clients where id=p_from_client_id and business_id=v_business_id) then
    raise exception 'Sending client does not belong to this business.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_business_id||':'||p_from_client_id::text));
  select public.patafix_client_charge_balance(p_from_client_id) into v_balance;
  if round(p_amount,2)>v_balance then raise exception 'Transfer exceeds the available client balance of KES %.',v_balance; end if;
  if round(p_amount,2)>v_loan.outstanding_balance then raise exception 'Transfer exceeds the selected loan balance of KES %.',v_loan.outstanding_balance; end if;
  select id into v_staff_id from public.loan_staff where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
    order by last_login desc nulls last,created_at desc limit 1;

  select
    coalesce(sum(greatest(total_due-total_paid,0) * case when principal_due+interest_due>0 then principal_due/(principal_due+interest_due) else 1 end),0),
    coalesce(sum(greatest(total_due-total_paid,0) * case when principal_due+interest_due>0 then interest_due/(principal_due+interest_due) else 0 end),0)
  into v_principal_remaining,v_interest_remaining
  from public.loan_schedules
  where loan_id=p_loan_id and status in ('pending','partial','overdue');
  if v_principal_remaining+v_interest_remaining>0 then
    v_interest_ratio := v_interest_remaining/(v_principal_remaining+v_interest_remaining);
  elsif v_loan.total_payable>0 then
    v_interest_ratio := greatest(0,least(1,v_loan.total_interest/v_loan.total_payable));
  end if;
  v_interest_portion := round(p_amount*v_interest_ratio,2);
  v_principal_portion := round(p_amount-v_interest_portion,2);
  v_payment_ts := (coalesce(p_transaction_date,current_date)::timestamp + interval '12 hours')::timestamptz;
  v_ref := coalesce(nullif(trim(p_reference),''),'LTR-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));
  v_receipt := 'WTR-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));

  insert into public.client_charge_transactions (
    business_id,client_id,loan_id,transaction_type,charge_type,amount,transaction_date,
    reference,payment_method,description,source_key,created_by
  ) values (
    v_business_id,p_from_client_id,p_loan_id,'loan_transfer_debit','other',round(p_amount,2),coalesce(p_transaction_date,current_date),
    v_ref,'charges_transfer','Transferred to loan '||v_loan.loan_no||': '||trim(p_reason),
    'loan-transfer:'||gen_random_uuid()::text,v_staff_id
  );
  insert into public.loan_repayments (
    business_id,loan_id,receipt_no,amount,payment_method,payment_reference,payment_date,
    principal_portion,interest_portion,penalty_portion,mpesa_confirmed,collected_by,notes,created_at
  ) values (
    v_business_id,p_loan_id,v_receipt,round(p_amount,2),'charges_transfer',v_ref,v_payment_ts,
    v_principal_portion,v_interest_portion,0,true,v_staff_id,
    'Transferred from another client Charges & Excess Account | '||trim(p_reason),v_payment_ts
  ) returning id into v_repayment_id;

  v_remaining := round(p_amount,2);
  for v_schedule in
    select * from public.loan_schedules
    where loan_id=p_loan_id and status in ('pending','partial','overdue') and total_paid<total_due
    order by due_date,installment_no for update
  loop
    exit when v_remaining<=0;
    v_apply := least(v_remaining,greatest(v_schedule.total_due-v_schedule.total_paid,0));
    v_new_total := round(v_schedule.total_paid+v_apply,2);
    v_schedule_principal_remaining:=greatest(v_schedule.principal_due-v_schedule.principal_paid,0);
    v_schedule_interest_remaining:=greatest(v_schedule.interest_due-v_schedule.interest_paid,0);
    if v_schedule_principal_remaining+v_schedule_interest_remaining>0 then
      v_schedule_interest_apply:=least(v_schedule_interest_remaining,round(v_apply*v_schedule_interest_remaining/(v_schedule_principal_remaining+v_schedule_interest_remaining),2));
    else
      v_schedule_interest_apply:=0;
    end if;
    v_schedule_principal_apply:=v_apply-v_schedule_interest_apply;
    if v_schedule_principal_apply>v_schedule_principal_remaining then
      v_schedule_interest_apply:=v_schedule_interest_apply+(v_schedule_principal_apply-v_schedule_principal_remaining);
      v_schedule_principal_apply:=v_schedule_principal_remaining;
    end if;
    update public.loan_schedules set
      total_paid=v_new_total,
      principal_paid=round(principal_paid+v_schedule_principal_apply,2),
      interest_paid=round(interest_paid+v_schedule_interest_apply,2),
      status=case when v_new_total>=total_due then 'paid' when due_date<current_date then 'overdue' else 'partial' end,
      paid_at=case when v_new_total>=total_due then v_payment_ts else null end
    where id=v_schedule.id;
    v_remaining := round(v_remaining-v_apply,2);
  end loop;

  v_new_balance := greatest(0,round(v_loan.outstanding_balance-p_amount,2));
  select coalesce(sum(greatest(total_due-total_paid,0)),0),min(due_date)
    into v_arrears,v_oldest_due
  from public.loan_schedules
  where loan_id=p_loan_id and status in ('pending','partial','overdue') and due_date<current_date and total_paid<total_due;
  if v_oldest_due is not null then v_overdue_days:=greatest(0,current_date-v_oldest_due); end if;
  update public.loans set
    total_paid=round(total_paid+p_amount,2),outstanding_balance=v_new_balance,
    status=case when v_new_balance<=0 then 'completed' else status end,
    arrears_amount=case when v_new_balance<=0 then 0 else round(v_arrears,2) end,
    overdue_days=case when v_new_balance<=0 then 0 else v_overdue_days end
  where id=p_loan_id;

  insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
  values (v_business_id,coalesce(p_transaction_date,current_date),v_ref,
    'Charges Account transfer to loan repayment '||v_loan.loan_no||' | '||trim(p_reason),
    'Loan Repayments','Charges & Excess Account',round(p_amount,2),false);
  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,new_value)
  values (v_business_id,v_staff_id,'client_charge_transferred_to_loan','loan_repayments',v_repayment_id::text,
    jsonb_build_object('from_client_id',p_from_client_id,'loan_id',p_loan_id,'loan_no',v_loan.loan_no,'amount',round(p_amount,2),'reference',v_ref));
  select public.patafix_client_charge_balance(p_from_client_id) into v_balance;
  return jsonb_build_object('ok',true,'repayment_id',v_repayment_id,'receipt_no',v_receipt,'wallet_balance',v_balance,'loan_balance',v_new_balance,'reference',v_ref);
end;
$$;

revoke all on function public.patafix_create_expense(date,text,text,numeric,text,text) from public;
revoke all on function public.patafix_decide_expense(uuid,text,text) from public;
revoke all on function public.patafix_refund_client_charge(uuid,numeric,date,text,text,text) from public;
revoke all on function public.patafix_transfer_client_charge(uuid,uuid,numeric,date,text,text) from public;
revoke all on function public.patafix_transfer_charge_to_loan(uuid,uuid,numeric,date,text,text) from public;
grant execute on function public.patafix_create_expense(date,text,text,numeric,text,text) to authenticated,service_role;
grant execute on function public.patafix_decide_expense(uuid,text,text) to authenticated,service_role;
grant execute on function public.patafix_refund_client_charge(uuid,numeric,date,text,text,text) to authenticated,service_role;
grant execute on function public.patafix_transfer_client_charge(uuid,uuid,numeric,date,text,text) to authenticated,service_role;
grant execute on function public.patafix_transfer_charge_to_loan(uuid,uuid,numeric,date,text,text) to authenticated,service_role;

select 'PataFix expenses and wallet actions ready' as result;
