-- PataFix capital/equity and company assets accounting upgrade.
-- Run once in the PataFix Supabase SQL Editor after deploying the updated index.html.

create extension if not exists pgcrypto;

alter table public.mpesa_callback_queue
  add column if not exists processing_status text,
  add column if not exists processing_message text,
  add column if not exists processed_at timestamptz;

create table if not exists public.patafix_company_assets (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  asset_no text not null,
  asset_date date not null default current_date,
  category text not null default 'Other',
  asset_name text not null,
  description text,
  purchase_amount numeric(14,2) not null check (purchase_amount > 0),
  current_value numeric(14,2) not null check (current_value >= 0),
  payment_method text not null default 'cash',
  payment_reference text,
  status text not null default 'active' check (status in ('active','disposed','written_off')),
  recorded_by uuid references public.loan_staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, asset_no)
);

create index if not exists patafix_company_assets_business_date_idx
  on public.patafix_company_assets (business_id, asset_date desc, created_at desc);

drop trigger if exists patafix_company_assets_updated_at on public.patafix_company_assets;
create trigger patafix_company_assets_updated_at before update on public.patafix_company_assets
for each row execute function public.set_updated_at();

alter table public.patafix_company_assets enable row level security;

drop policy if exists patafix_company_assets_select on public.patafix_company_assets;
create policy patafix_company_assets_select on public.patafix_company_assets
for select to authenticated
using (
  public.patafix_can_access_business(business_id)
  and public.patafix_has_permission('view_accounting',array['admin']::text[])
);

revoke insert, update, delete on public.patafix_company_assets from anon, authenticated;
grant select on public.patafix_company_assets to authenticated;
grant all on public.patafix_company_assets to service_role;

create or replace function public.patafix_current_staff_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id
  from public.loan_staff
  where business_id = public.current_patafix_business_id()
    and is_active = true
    and (
      auth_user_id = auth.uid()
      or lower(trim(email)) = lower(trim(coalesce(auth.jwt() ->> 'email','')))
    )
  order by last_login desc nulls last, created_at desc
  limit 1;
$$;

create or replace function public.patafix_payment_account(p_payment_method text)
returns text
language sql
immutable
as $$
  select case lower(coalesce(nullif(trim(p_payment_method),''),'cash'))
    when 'mpesa' then 'M-Pesa'
    when 'm-pesa' then 'M-Pesa'
    when 'bank' then 'Bank'
    when 'bank_transfer' then 'Bank'
    when 'imprest' then 'Imprest'
    else 'Cash'
  end;
$$;

create or replace function public.patafix_record_owner_capital(
  p_capital_date date,
  p_amount numeric,
  p_payment_method text default 'cash',
  p_reference text default null,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid := public.patafix_current_staff_id();
  v_ref text;
begin
  if v_business_id is null or v_staff_id is null then raise exception 'No active PataFix staff account was found.'; end if;
  if not public.patafix_has_permission('view_accounting',array['admin']::text[]) then
    raise exception 'You do not have permission to record capital entries.';
  end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Capital amount must be greater than zero.'; end if;

  v_ref := coalesce(nullif(trim(p_reference),''),'CAP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));

  insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
  values (
    v_business_id,coalesce(p_capital_date,current_date),v_ref,
    coalesce(nullif(trim(p_description),''),'Owner capital introduced into the business'),
    public.patafix_payment_account(p_payment_method),'Owner Capital / Equity',round(p_amount,2),false
  );

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,new_value)
  values (v_business_id,v_staff_id,'owner_capital_recorded','journal_entries',v_ref,
    jsonb_build_object('amount',round(p_amount,2),'reference',v_ref,'payment_method',p_payment_method));

  return jsonb_build_object('ok',true,'reference',v_ref,'amount',round(p_amount,2));
end;
$$;

create or replace function public.patafix_record_company_asset(
  p_asset_date date,
  p_category text,
  p_asset_name text,
  p_description text,
  p_purchase_amount numeric,
  p_current_value numeric default null,
  p_payment_method text default 'cash',
  p_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid := public.patafix_current_staff_id();
  v_asset public.patafix_company_assets%rowtype;
  v_asset_no text;
  v_ref text;
begin
  if v_business_id is null or v_staff_id is null then raise exception 'No active PataFix staff account was found.'; end if;
  if not public.patafix_has_permission('view_accounting',array['admin']::text[]) then
    raise exception 'You do not have permission to record company assets.';
  end if;
  if coalesce(p_purchase_amount,0) <= 0 then raise exception 'Asset amount must be greater than zero.'; end if;
  if nullif(trim(coalesce(p_asset_name,'')),'') is null then raise exception 'Enter the asset name.'; end if;

  v_asset_no := 'AST-' || to_char(coalesce(p_asset_date,current_date),'YYYYMMDD') || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
  v_ref := coalesce(nullif(trim(p_reference),''),v_asset_no);

  insert into public.patafix_company_assets (
    business_id,asset_no,asset_date,category,asset_name,description,purchase_amount,current_value,
    payment_method,payment_reference,recorded_by
  ) values (
    v_business_id,v_asset_no,coalesce(p_asset_date,current_date),coalesce(nullif(trim(p_category),''),'Other'),
    trim(p_asset_name),nullif(trim(coalesce(p_description,'')),''),round(p_purchase_amount,2),
    round(coalesce(p_current_value,p_purchase_amount),2),lower(coalesce(nullif(trim(p_payment_method),''),'cash')),
    nullif(trim(coalesce(p_reference,'')),''),v_staff_id
  ) returning * into v_asset;

  insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
  values (
    v_business_id,v_asset.asset_date,v_ref,
    'Company asset purchase - '||v_asset.asset_name||coalesce(' | '||nullif(v_asset.description,''),''),
    'Company Assets',public.patafix_payment_account(p_payment_method),v_asset.purchase_amount,false
  );

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,new_value)
  values (v_business_id,v_staff_id,'company_asset_recorded','patafix_company_assets',v_asset.id::text,to_jsonb(v_asset));

  return to_jsonb(v_asset);
end;
$$;

create or replace function public.patafix_move_suspense_to_capital(
  p_entry_id uuid,
  p_entry_type text,
  p_amount numeric,
  p_reference text default null,
  p_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_staff_id uuid := public.patafix_current_staff_id();
  v_entry_type text := lower(trim(coalesce(p_entry_type,'')));
  v_ref text := nullif(trim(coalesce(p_reference,'')),'');
  v_source_amount numeric(14,2);
  v_source_ref text;
  v_source_account text;
  v_queue public.mpesa_callback_queue%rowtype;
  v_suspense public.unmatched_payments%rowtype;
begin
  if v_business_id is null or v_staff_id is null then raise exception 'No active PataFix staff account was found.'; end if;
  if not public.patafix_has_permission('view_accounting',array['admin']::text[]) then
    raise exception 'You do not have permission to move suspense funds to capital.';
  end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Amount must be greater than zero.'; end if;

  if v_entry_type = 'mpesa' then
    select * into v_queue from public.mpesa_callback_queue
    where id = p_entry_id and business_id = v_business_id and coalesce(confirmed,false) = false
    for update;
    if v_queue.id is null then raise exception 'Pending M-Pesa suspense record was not found.'; end if;
    v_source_amount := round(v_queue.trans_amount,2);
    v_source_ref := coalesce(v_queue.trans_id,v_ref,'CAP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));
    v_source_account := coalesce(v_queue.bill_ref_number,'');
    if round(p_amount,2) <> v_source_amount then raise exception 'Move the full suspense amount of KES % to capital, or split the transaction manually first.',v_source_amount; end if;

    update public.mpesa_callback_queue
    set confirmed = true,
        unmatched = false,
        unmatched_reason = 'Moved to Owner Capital / Equity',
        processing_status = 'moved_to_capital',
        processing_message = 'Transferred from suspense to capital account',
        processed_at = now()
    where id = p_entry_id;
  elsif v_entry_type = 'unmatched' then
    select * into v_suspense from public.unmatched_payments
    where id = p_entry_id and business_id = v_business_id and coalesce(resolved,false) = false
    for update;
    if v_suspense.id is null then raise exception 'Pending suspense record was not found.'; end if;
    v_source_amount := round(v_suspense.amount,2);
    v_source_ref := coalesce(v_suspense.mpesa_reference,v_suspense.invoice_id,v_ref,'CAP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));
    v_source_account := coalesce(v_suspense.account_number,'');
    if round(p_amount,2) <> v_source_amount then raise exception 'Move the full suspense amount of KES % to capital, or split the transaction manually first.',v_source_amount; end if;

    update public.unmatched_payments
    set resolved = true,
        resolved_at = now(),
        resolved_by = v_staff_id
    where id = p_entry_id;
  else
    raise exception 'Unsupported suspense entry type.';
  end if;

  v_ref := coalesce(v_source_ref,v_ref,'CAP-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)));

  update public.mpesa_callback_queue
  set confirmed = true,
      unmatched = false,
      unmatched_reason = 'Moved to Owner Capital / Equity',
      processing_status = 'moved_to_capital',
      processing_message = 'Transferred from suspense to capital account',
      processed_at = now()
  where business_id = v_business_id
    and trans_id = v_ref
    and coalesce(confirmed,false) = false;

  update public.unmatched_payments
  set resolved = true,
      resolved_at = now(),
      resolved_by = v_staff_id
  where business_id = v_business_id
    and mpesa_reference = v_ref
    and coalesce(resolved,false) = false;

  insert into public.journal_entries (business_id,date,ref,description,debit,credit,amount,synced)
  values (
    v_business_id,current_date,v_ref,
    coalesce(nullif(trim(p_description),''),'Suspense funds moved to Owner Capital / Equity')||
      case when v_source_account <> '' then ' | Account ref: '||v_source_account else '' end,
    'Suspense Account','Owner Capital / Equity',round(p_amount,2),false
  );

  insert into public.loan_audit_log (business_id,user_id,action,table_name,record_id,new_value)
  values (v_business_id,v_staff_id,'suspense_moved_to_capital','journal_entries',v_ref,
    jsonb_build_object('entry_id',p_entry_id,'entry_type',v_entry_type,'amount',round(p_amount,2),'reference',v_ref));

  return jsonb_build_object('ok',true,'reference',v_ref,'amount',round(p_amount,2));
end;
$$;

revoke all on function public.patafix_current_staff_id() from public;
revoke all on function public.patafix_payment_account(text) from public;
revoke all on function public.patafix_record_owner_capital(date,numeric,text,text,text) from public;
revoke all on function public.patafix_record_company_asset(date,text,text,text,numeric,numeric,text,text) from public;
revoke all on function public.patafix_move_suspense_to_capital(uuid,text,numeric,text,text) from public;

grant execute on function public.patafix_current_staff_id() to authenticated, service_role;
grant execute on function public.patafix_payment_account(text) to authenticated, service_role;
grant execute on function public.patafix_record_owner_capital(date,numeric,text,text,text) to authenticated, service_role;
grant execute on function public.patafix_record_company_asset(date,text,text,text,numeric,numeric,text,text) to authenticated, service_role;
grant execute on function public.patafix_move_suspense_to_capital(uuid,text,numeric,text,text) to authenticated, service_role;

select 'PataFix capital and assets accounting ready' as result;
