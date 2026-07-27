-- PataFix client charges wallet
-- Run this file once in the PataFix Supabase SQL Editor before deploying index.html.

create table if not exists public.client_charge_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  client_id uuid not null references public.loan_clients(id) on delete cascade,
  loan_id uuid references public.loans(id) on delete set null,
  transaction_type text not null check (transaction_type in ('deposit','excess_deposit','fee_debit','adjustment_credit','adjustment_debit')),
  charge_type text not null default 'other' check (charge_type in ('processing','registration','excess','other')),
  amount numeric(14,2) not null check (amount > 0),
  transaction_date date not null default current_date,
  reference text,
  payment_method text,
  description text,
  source_key text,
  created_by uuid references public.loan_staff(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists client_charge_transactions_source_key_idx
  on public.client_charge_transactions (business_id, source_key)
  where source_key is not null;

create index if not exists client_charge_transactions_client_idx
  on public.client_charge_transactions (business_id, client_id, transaction_date, created_at);

alter table public.client_charge_transactions enable row level security;

drop policy if exists patafix_business_select on public.client_charge_transactions;
create policy patafix_business_select on public.client_charge_transactions for select to authenticated
using (business_id = public.current_patafix_business_id());

drop policy if exists patafix_business_insert on public.client_charge_transactions;
create policy patafix_business_insert on public.client_charge_transactions for insert to authenticated
with check (business_id = public.current_patafix_business_id());

drop policy if exists patafix_business_update on public.client_charge_transactions;
create policy patafix_business_update on public.client_charge_transactions for update to authenticated
using (business_id = public.current_patafix_business_id())
with check (business_id = public.current_patafix_business_id());

drop policy if exists patafix_business_delete on public.client_charge_transactions;
create policy patafix_business_delete on public.client_charge_transactions for delete to authenticated
using (business_id = public.current_patafix_business_id());

create or replace function public.patafix_client_charge_balance(p_client_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(
    case
      when transaction_type in ('deposit','excess_deposit','adjustment_credit') then amount
      else -amount
    end
  ),0)::numeric(14,2)
  from public.client_charge_transactions
  where business_id = public.current_patafix_business_id()
    and client_id = p_client_id;
$$;

create or replace function public.patafix_deposit_client_charge(
  p_client_id uuid,
  p_amount numeric,
  p_transaction_type text,
  p_charge_type text,
  p_transaction_date date,
  p_reference text default null,
  p_payment_method text default null,
  p_description text default null,
  p_source_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid;
  v_transaction_id uuid;
  v_balance numeric(14,2);
begin
  if v_business_id is null then
    raise exception 'No active PataFix staff account was found.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Deposit amount must be greater than zero.';
  end if;
  if p_transaction_type not in ('deposit','excess_deposit','adjustment_credit') then
    raise exception 'Invalid wallet deposit transaction type.';
  end if;
  if not exists (
    select 1 from public.loan_clients
    where id = p_client_id and business_id = v_business_id
  ) then
    raise exception 'Client does not belong to this business.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_business_id || ':' || p_client_id::text));
  select id into v_staff_id from public.loan_staff
  where auth_user_id = auth.uid() and business_id = v_business_id and is_active = true
  limit 1;

  insert into public.client_charge_transactions (
    business_id,client_id,transaction_type,charge_type,amount,transaction_date,
    reference,payment_method,description,source_key,created_by
  ) values (
    v_business_id,p_client_id,p_transaction_type,
    case when p_charge_type in ('processing','registration','excess','other') then p_charge_type else 'other' end,
    round(p_amount,2),coalesce(p_transaction_date,current_date),nullif(trim(p_reference),''),
    nullif(trim(p_payment_method),''),nullif(trim(p_description),''),nullif(trim(p_source_key),''),v_staff_id
  )
  on conflict (business_id, source_key) where source_key is not null do nothing
  returning id into v_transaction_id;

  select public.patafix_client_charge_balance(p_client_id) into v_balance;
  return jsonb_build_object('ok',true,'transaction_id',v_transaction_id,'balance',v_balance,'duplicate',v_transaction_id is null);
end;
$$;

create or replace function public.patafix_consume_client_charges(
  p_client_id uuid,
  p_loan_id uuid,
  p_processing_amount numeric,
  p_registration_amount numeric,
  p_transaction_date date,
  p_reference text default null
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
  v_required numeric(14,2) := round(coalesce(p_processing_amount,0) + coalesce(p_registration_amount,0),2);
begin
  if v_business_id is null then
    raise exception 'No active PataFix staff account was found.';
  end if;
  if coalesce(p_processing_amount,0) < 0 or coalesce(p_registration_amount,0) < 0 then
    raise exception 'Fee amounts cannot be negative.';
  end if;
  if not exists (
    select 1 from public.loans
    where id = p_loan_id and client_id = p_client_id and business_id = v_business_id
  ) then
    raise exception 'Loan does not belong to this client and business.';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_business_id || ':' || p_client_id::text));
  select public.patafix_client_charge_balance(p_client_id) into v_balance;

  if v_balance < v_required then
    return jsonb_build_object(
      'ok',false,'balance',v_balance,'required',v_required,
      'shortfall',round(v_required-v_balance,2)
    );
  end if;

  select id into v_staff_id from public.loan_staff
  where auth_user_id = auth.uid() and business_id = v_business_id and is_active = true
  limit 1;

  if coalesce(p_processing_amount,0) > 0 then
    insert into public.client_charge_transactions (
      business_id,client_id,loan_id,transaction_type,charge_type,amount,
      transaction_date,reference,description,source_key,created_by
    ) values (
      v_business_id,p_client_id,p_loan_id,'fee_debit','processing',round(p_processing_amount,2),
      coalesce(p_transaction_date,current_date),nullif(trim(p_reference),''),
      'Processing/application fee used during disbursement','disbursement:'||p_loan_id::text||':processing',v_staff_id
    ) on conflict (business_id, source_key) where source_key is not null do nothing;
  end if;

  if coalesce(p_registration_amount,0) > 0 then
    insert into public.client_charge_transactions (
      business_id,client_id,loan_id,transaction_type,charge_type,amount,
      transaction_date,reference,description,source_key,created_by
    ) values (
      v_business_id,p_client_id,p_loan_id,'fee_debit','registration',round(p_registration_amount,2),
      coalesce(p_transaction_date,current_date),nullif(trim(p_reference),''),
      'One-time registration fee used during first-loan disbursement','disbursement:'||p_loan_id::text||':registration',v_staff_id
    ) on conflict (business_id, source_key) where source_key is not null do nothing;
  end if;

  select public.patafix_client_charge_balance(p_client_id) into v_balance;
  return jsonb_build_object('ok',true,'balance',v_balance,'required',v_required,'shortfall',0);
end;
$$;

revoke all on function public.patafix_client_charge_balance(uuid) from public;
revoke all on function public.patafix_deposit_client_charge(uuid,numeric,text,text,date,text,text,text,text) from public;
revoke all on function public.patafix_consume_client_charges(uuid,uuid,numeric,numeric,date,text) from public;
grant execute on function public.patafix_client_charge_balance(uuid) to authenticated, service_role;
grant execute on function public.patafix_deposit_client_charge(uuid,numeric,text,text,date,text,text,text,text) to authenticated, service_role;
grant execute on function public.patafix_consume_client_charges(uuid,uuid,numeric,numeric,date,text) to authenticated, service_role;

-- Migrate existing excess deposits. Loan numbers identify the client reliably.
insert into public.client_charge_transactions (
  business_id,client_id,loan_id,transaction_type,charge_type,amount,
  transaction_date,reference,payment_method,description,source_key
)
select
  j.business_id,l.client_id,l.id,'excess_deposit','excess',j.amount,j.date,j.ref,j.debit,
  j.description,'legacy-journal:'||j.id::text
from public.journal_entries j
join public.loans l
  on l.business_id = j.business_id
 and (
   lower(j.description) like '%loan '||lower(l.loan_no)||' |%'
   or lower(j.description) like '%loan '||lower(l.loan_no)
 )
where lower(coalesce(j.description,'')) like '%excess repayment%'
on conflict (business_id, source_key) where source_key is not null do nothing;

-- Migrate charge payments manually uploaded against a client. These remain available
-- until a future disbursement consumes them.
insert into public.client_charge_transactions (
  business_id,client_id,transaction_type,charge_type,amount,transaction_date,
  reference,payment_method,description,source_key
)
select
  j.business_id,c.id,'deposit',
  case when lower(coalesce(j.credit,'')) like '%registration%' then 'registration' else 'processing' end,
  j.amount,j.date,j.ref,j.debit,j.description,'legacy-journal:'||j.id::text
from public.journal_entries j
join public.loan_clients c
  on c.business_id = j.business_id
 and (
   lower(j.description) like '%client id: '||lower(c.id::text)||'%'
   or lower(j.description) like '%paid by '||lower(c.full_name)||'%'
 )
where lower(coalesce(j.description,'')) like '%paid by%'
  and lower(coalesce(j.description,'')) not like '%excess repayment%'
on conflict (business_id, source_key) where source_key is not null do nothing;

-- Historic fees created directly during disbursement had no separate wallet deposit.
-- Add an equal opening deposit and fee debit so history is visible without producing
-- a false negative balance.
with historic_fees as (
  select distinct on (j.id)
    j.id journal_id,j.business_id,j.date,j.ref,j.description,j.amount,
    coalesce(l.client_id,c.id) client_id,l.id loan_id,
    case when lower(coalesce(j.credit,'')) like '%registration%' then 'registration' else 'processing' end charge_type
  from public.journal_entries j
  left join public.loans l
    on l.business_id = j.business_id
   and (
     lower(j.description) like '%loan '||lower(l.loan_no)||' |%'
     or lower(j.description) like '%loan '||lower(l.loan_no)
   )
  left join public.loan_clients c
    on c.business_id = j.business_id
   and (
     lower(j.description) like '%client id: '||lower(c.id::text)||'%'
     or lower(j.description) like '%registration fee%'||lower(c.full_name)||'%'
   )
  where (lower(coalesce(j.credit,'')) like '%processing fee income%'
      or lower(coalesce(j.credit,'')) like '%registration fee income%')
    and lower(coalesce(j.description,'')) not like '%paid by%'
    and coalesce(l.client_id,c.id) is not null
)
insert into public.client_charge_transactions (
  business_id,client_id,loan_id,transaction_type,charge_type,amount,
  transaction_date,reference,payment_method,description,source_key
)
select business_id,client_id,loan_id,'deposit',charge_type,amount,date,ref,'legacy',
  'Historic fee payment received before wallet tracking',
  'legacy-fee-deposit:'||journal_id::text
from historic_fees
union all
select business_id,client_id,loan_id,'fee_debit',charge_type,amount,date,ref,null,
  'Historic fee used during disbursement',
  'legacy-fee-debit:'||journal_id::text
from historic_fees
on conflict (business_id, source_key) where source_key is not null do nothing;

select
  count(*) as wallet_transactions,
  coalesce(sum(case when transaction_type in ('deposit','excess_deposit','adjustment_credit') then amount else -amount end),0) as available_balance
from public.client_charge_transactions;
