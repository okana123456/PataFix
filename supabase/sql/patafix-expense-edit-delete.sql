-- PataFix expense edit/delete actions.
-- Run once in the PataFix Supabase SQL Editor before deploying index.html.

alter table public.journal_entries
  add column if not exists source_key text,
  add column if not exists branch_name text not null default 'Head Office';

create index if not exists journal_entries_source_key_idx
  on public.journal_entries (business_id, source_key)
  where source_key is not null;

create or replace function public.patafix_update_expense(
  p_expense_id uuid,
  p_expense_date date,
  p_category text,
  p_description text,
  p_amount numeric,
  p_payment_method text default 'cash',
  p_payment_reference text default null,
  p_branch_name text default 'Head Office'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_old public.patafix_expenses%rowtype;
  v_expense public.patafix_expenses%rowtype;
  v_cash_account text;
  v_source_key text := 'expense:' || p_expense_id::text;
begin
  if not public.patafix_has_permission('approve_expenses',array['admin']::text[]) then
    raise exception 'Only an administrator can edit expenses.';
  end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Expense amount must be greater than zero.'; end if;
  if nullif(trim(coalesce(p_category,'')),'') is null then raise exception 'Select an expense category.'; end if;
  if nullif(trim(coalesce(p_description,'')),'') is null then raise exception 'Enter the expense description.'; end if;

  select * into v_old
  from public.patafix_expenses
  where id=p_expense_id and business_id=v_business_id
  for update;
  if v_old.id is null then raise exception 'Expense request was not found.'; end if;

  select id into v_staff_id from public.loan_staff
  where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
  order by last_login desc nulls last, created_at desc limit 1;

  update public.patafix_expenses set
    expense_date=coalesce(p_expense_date,current_date),
    category=trim(p_category),
    description=trim(p_description),
    amount=round(p_amount,2),
    payment_method=lower(coalesce(nullif(trim(p_payment_method),''),'cash')),
    payment_reference=nullif(trim(p_payment_reference),''),
    branch_name=coalesce(nullif(trim(p_branch_name),''),'Head Office')
  where id=p_expense_id and business_id=v_business_id
  returning * into v_expense;

  if v_expense.status='approved' then
    v_cash_account := case v_expense.payment_method
      when 'mpesa' then 'M-Pesa'
      when 'bank' then 'Bank'
      when 'imprest' then 'Imprest'
      else 'Cash'
    end;

    update public.journal_entries set
      date=v_expense.expense_date,
      ref=coalesce(v_expense.payment_reference,v_expense.expense_no),
      description='Approved expense - '||v_expense.category||' | '||v_expense.description||' | Branch: '||coalesce(v_expense.branch_name,'Head Office'),
      debit='Expense - '||v_expense.category,
      credit=v_cash_account,
      amount=v_expense.amount,
      branch_name=coalesce(v_expense.branch_name,'Head Office'),
      source_key=v_source_key,
      synced=false
    where id=(
      select j.id from public.journal_entries j
      where j.business_id=v_business_id
        and (j.source_key=v_source_key or (
          j.source_key is null
          and j.ref=coalesce(v_old.payment_reference,v_old.expense_no)
          and j.amount=v_old.amount
          and j.description='Approved expense - '||v_old.category||' | '||v_old.description||' | Branch: '||coalesce(v_old.branch_name,'Head Office')
        ))
      order by case when j.source_key=v_source_key then 0 else 1 end, j.created_at desc
      limit 1
    );

    if not found then
      insert into public.journal_entries
        (business_id,date,ref,description,debit,credit,amount,synced,branch_name,source_key)
      values
        (v_business_id,v_expense.expense_date,coalesce(v_expense.payment_reference,v_expense.expense_no),
         'Approved expense - '||v_expense.category||' | '||v_expense.description||' | Branch: '||coalesce(v_expense.branch_name,'Head Office'),
         'Expense - '||v_expense.category,v_cash_account,v_expense.amount,false,
         coalesce(v_expense.branch_name,'Head Office'),v_source_key);
    end if;
  end if;

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,old_value,new_value)
  values (v_business_id,v_staff_id,'expense_edited','patafix_expenses',v_expense.id::text,to_jsonb(v_old),to_jsonb(v_expense));
  return to_jsonb(v_expense);
end;
$$;

create or replace function public.patafix_delete_expense(p_expense_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_expense public.patafix_expenses%rowtype;
  v_source_key text := 'expense:' || p_expense_id::text;
  v_journal_rows integer := 0;
begin
  if not public.patafix_has_permission('approve_expenses',array['admin']::text[]) then
    raise exception 'Only an administrator can delete expenses.';
  end if;

  select * into v_expense
  from public.patafix_expenses
  where id=p_expense_id and business_id=v_business_id
  for update;
  if v_expense.id is null then raise exception 'Expense request was not found.'; end if;

  select id into v_staff_id from public.loan_staff
  where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
  order by last_login desc nulls last, created_at desc limit 1;

  if v_expense.status='approved' then
    delete from public.journal_entries j
    where j.business_id=v_business_id
      and (j.source_key=v_source_key or (
        j.source_key is null
        and j.ref=coalesce(v_expense.payment_reference,v_expense.expense_no)
        and j.amount=v_expense.amount
        and j.description='Approved expense - '||v_expense.category||' | '||v_expense.description||' | Branch: '||coalesce(v_expense.branch_name,'Head Office')
      ));
    get diagnostics v_journal_rows = row_count;
  end if;

  delete from public.patafix_expenses
  where id=p_expense_id and business_id=v_business_id;

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,old_value,new_value)
  values (v_business_id,v_staff_id,'expense_deleted','patafix_expenses',v_expense.id::text,to_jsonb(v_expense),
    jsonb_build_object('deleted',true,'accounting_entries_removed',v_journal_rows));
  return jsonb_build_object('ok',true,'expense_no',v_expense.expense_no,'accounting_entries_removed',v_journal_rows);
end;
$$;

revoke all on function public.patafix_update_expense(uuid,date,text,text,numeric,text,text,text) from public;
revoke all on function public.patafix_delete_expense(uuid) from public;
grant execute on function public.patafix_update_expense(uuid,date,text,text,numeric,text,text,text) to authenticated,service_role;
grant execute on function public.patafix_delete_expense(uuid) to authenticated,service_role;

-- Link future approved expenses directly to their accounting entry.
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
  if v_decision='rejected' and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter the rejection reason.'; end if;

  select * into v_expense from public.patafix_expenses
  where id=p_expense_id and business_id=v_business_id for update;
  if v_expense.id is null then raise exception 'Expense request was not found.'; end if;
  if v_expense.status <> 'pending' then raise exception 'This expense has already been decided.'; end if;

  select id into v_staff_id from public.loan_staff
  where business_id=v_business_id and is_active=true
    and (auth_user_id=auth.uid() or lower(trim(email))=lower(trim(coalesce(auth.jwt()->>'email',''))))
  order by last_login desc nulls last, created_at desc limit 1;

  update public.patafix_expenses set
    status=v_decision,approved_by=v_staff_id,approved_at=now(),
    rejection_reason=case when v_decision='rejected' then trim(p_reason) else null end
  where id=p_expense_id returning * into v_expense;

  if v_decision='approved' then
    v_cash_account := case v_expense.payment_method when 'mpesa' then 'M-Pesa' when 'bank' then 'Bank' when 'imprest' then 'Imprest' else 'Cash' end;
    insert into public.journal_entries
      (business_id,date,ref,description,debit,credit,amount,synced,branch_name,source_key)
    values
      (v_business_id,v_expense.expense_date,coalesce(v_expense.payment_reference,v_expense.expense_no),
       'Approved expense - '||v_expense.category||' | '||v_expense.description||' | Branch: '||coalesce(v_expense.branch_name,'Head Office'),
       'Expense - '||v_expense.category,v_cash_account,v_expense.amount,false,
       coalesce(v_expense.branch_name,'Head Office'),'expense:'||v_expense.id::text);
  end if;

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,old_value,new_value)
  values (v_business_id,v_staff_id,'expense_'||v_decision,'patafix_expenses',v_expense.id::text,
    jsonb_build_object('status','pending'),to_jsonb(v_expense));
  return to_jsonb(v_expense);
end;
$$;

revoke all on function public.patafix_decide_expense(uuid,text,text) from public;
grant execute on function public.patafix_decide_expense(uuid,text,text) to authenticated,service_role;

select 'PataFix expense edit and delete actions ready' as status;
