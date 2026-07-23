-- PataFix complete database setup
-- Run this entire file once in the NEW PataFix Supabase SQL Editor.

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table if not exists public.loan_staff (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  auth_user_id uuid unique,
  name text not null,
  email text not null,
  phone text,
  role text not null default 'loan_officer',
  is_active boolean not null default true,
  last_login timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, email)
);

create table if not exists public.loan_settings (
  id uuid primary key default gen_random_uuid(),
  business_id text not null unique,
  company_name text not null default 'PataFix',
  company_phone text,
  company_email text,
  company_address text,
  currency text not null default 'KES',
  default_grace_period integer not null default 7,
  default_late_penalty_pct numeric(8,4) not null default 5,
  default_processing_fee_pct numeric(8,4) not null default 0,
  standard_weekly_rate numeric(8,4) not null default 5,
  micro_weekly_rate numeric(8,4) not null default 5,
  micro_threshold numeric(14,2) not null default 5000,
  loan_no_prefix text not null default 'LN',
  app_no_prefix text not null default 'APP',
  receipt_no_prefix text not null default 'RCP',
  disbursement_method text not null default 'mpesa',
  mpesa_consumer_key text,
  mpesa_consumer_secret text,
  mpesa_passkey text,
  mpesa_shortcode text,
  daraja_environment text not null default 'production',
  mpesa_auto_confirm boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.loan_clients (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  full_name text not null,
  id_number text,
  phone text,
  alternative_phone text,
  email text,
  gender text,
  dob date,
  address text,
  occupation text,
  employer text,
  monthly_income numeric(14,2) not null default 0,
  next_of_kin_name text,
  next_of_kin_phone text,
  next_of_kin_relation text,
  notes text,
  status text not null default 'active',
  loan_officer_id uuid references public.loan_staff(id) on delete set null,
  created_by uuid references public.loan_staff(id) on delete set null,
  photo_path text,
  asset_photo_paths jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.loan_products (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  name text not null,
  description text,
  min_amount numeric(14,2) not null default 0,
  max_amount numeric(14,2) not null default 0,
  interest_rate numeric(8,4) not null default 5,
  interest_type text not null default 'flat',
  interest_period text not null default 'weekly',
  min_term_weeks integer not null default 1,
  max_term_weeks integer not null default 52,
  processing_fee_pct numeric(8,4) not null default 0,
  late_penalty_pct numeric(8,4) not null default 5,
  grace_period_days integer not null default 3,
  requires_guarantor boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, name)
);

create table if not exists public.loan_applications (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  application_no text not null,
  client_id uuid not null references public.loan_clients(id) on delete cascade,
  product_id uuid references public.loan_products(id) on delete set null,
  loan_officer_id uuid references public.loan_staff(id) on delete set null,
  applied_amount numeric(14,2) not null,
  applied_term_weeks integer not null,
  purpose text,
  loan_type text default 'new_loan',
  guarantor_name text,
  guarantor_phone text,
  guarantor_relationship text,
  status text not null default 'submitted',
  application_date date not null default current_date,
  approved_by uuid references public.loan_staff(id) on delete set null,
  approved_at timestamptz,
  reviewed_by uuid references public.loan_staff(id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, application_no)
);

create table if not exists public.loans (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_no text not null,
  application_id uuid references public.loan_applications(id) on delete set null,
  client_id uuid not null references public.loan_clients(id) on delete cascade,
  loan_officer_id uuid references public.loan_staff(id) on delete set null,
  principal_amount numeric(14,2) not null default 0,
  disbursed_amount numeric(14,2) not null default 0,
  interest_rate numeric(8,4) not null default 5,
  interest_type text not null default 'flat',
  term_weeks integer not null default 1,
  processing_fee numeric(14,2) not null default 0,
  total_interest numeric(14,2) not null default 0,
  total_payable numeric(14,2) not null default 0,
  weekly_installment numeric(14,2) not null default 0,
  disbursement_method text,
  disbursement_reference text,
  disbursement_date date,
  first_repayment_date date,
  maturity_date date,
  status text not null default 'active',
  outstanding_balance numeric(14,2) not null default 0,
  total_paid numeric(14,2) not null default 0,
  arrears_amount numeric(14,2) not null default 0,
  overdue_days integer not null default 0,
  loan_type text default 'new_loan',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, loan_no)
);

create table if not exists public.loan_schedules (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_id uuid not null references public.loans(id) on delete cascade,
  installment_no integer not null,
  due_date date not null,
  principal_due numeric(14,2) not null default 0,
  interest_due numeric(14,2) not null default 0,
  total_due numeric(14,2) not null default 0,
  principal_paid numeric(14,2) not null default 0,
  interest_paid numeric(14,2) not null default 0,
  total_paid numeric(14,2) not null default 0,
  penalty_charged numeric(14,2) not null default 0,
  status text not null default 'pending',
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (loan_id, installment_no)
);

create table if not exists public.loan_repayments (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_id uuid not null references public.loans(id) on delete cascade,
  receipt_no text not null,
  amount numeric(14,2) not null check (amount > 0),
  payment_method text not null default 'cash',
  payment_reference text,
  payment_date timestamptz not null default now(),
  principal_portion numeric(14,2) not null default 0,
  interest_portion numeric(14,2) not null default 0,
  penalty_portion numeric(14,2) not null default 0,
  mpesa_confirmed boolean not null default false,
  collected_by uuid references public.loan_staff(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, receipt_no)
);

create table if not exists public.loan_penalties (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_id uuid not null references public.loans(id) on delete cascade,
  penalty_amount numeric(14,2) not null default 0,
  reason text,
  date_charged date not null default current_date,
  is_waived boolean not null default false,
  waived_reason text,
  waived_by uuid references public.loan_staff(id) on delete set null,
  waived_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.loan_follow_ups (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_id uuid references public.loans(id) on delete cascade,
  client_id uuid references public.loan_clients(id) on delete cascade,
  officer_id uuid references public.loan_staff(id) on delete set null,
  follow_up_type text,
  notes text,
  outcome text,
  follow_up_date date not null default current_date,
  next_follow_up_date date,
  created_at timestamptz not null default now()
);

create table if not exists public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  date date not null default current_date,
  ref text,
  description text,
  debit text,
  credit text,
  amount numeric(14,2) not null default 0,
  synced boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.loan_audit_log (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  user_id uuid references public.loan_staff(id) on delete set null,
  action text not null,
  table_name text,
  record_id text,
  old_value jsonb,
  new_value jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.loan_billing_cycles (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  billing_month date not null,
  amount numeric(14,2) not null default 3000,
  status text not null default 'pending',
  phone text,
  merchant_request_id text,
  checkout_request_id text,
  receipt_number text,
  result_code text,
  result_description text,
  paid_at timestamptz,
  paid_until date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, billing_month)
);

create table if not exists public.mpesa_callback_queue (
  id uuid primary key default gen_random_uuid(),
  business_id text,
  transaction_type text,
  trans_id text not null unique,
  trans_time text,
  trans_amount numeric(14,2) not null default 0,
  business_short_code text,
  bill_ref_number text,
  msisdn text,
  first_name text,
  raw_payload jsonb,
  confirmed boolean not null default false,
  unmatched boolean not null default false,
  unmatched_reason text,
  loan_id uuid references public.loans(id) on delete set null,
  repayment_id uuid references public.loan_repayments(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.unmatched_payments (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  account_number text,
  amount numeric(14,2) not null default 0,
  payer_phone text,
  payer_name text,
  mpesa_reference text,
  invoice_id text,
  payment_date timestamptz not null default now(),
  raw_payload jsonb,
  resolved boolean not null default false,
  resolved_at timestamptz,
  resolved_by uuid references public.loan_staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Attach incoming callback rows to the correct business even when an older
-- callback function only sends the Paybill shortcode or business code.
create or replace function public.set_callback_business_id()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.business_id is null or trim(new.business_id) = '' then
    select s.business_id into new.business_id
    from public.loan_settings s
    where s.mpesa_shortcode = new.business_short_code
       or s.business_id = new.business_short_code
    limit 1;
  end if;
  return new;
end;
$$;

drop trigger if exists set_callback_business_id on public.mpesa_callback_queue;
create trigger set_callback_business_id
before insert or update on public.mpesa_callback_queue
for each row execute function public.set_callback_business_id();

-- Prevent duplicate clients and duplicate M-Pesa repayments within one business.
create unique index if not exists loan_clients_business_id_number_unique
  on public.loan_clients (business_id, lower(trim(id_number)))
  where id_number is not null and trim(id_number) <> '';
create unique index if not exists loan_clients_business_phone_unique
  on public.loan_clients (business_id, regexp_replace(phone, '\D', '', 'g'))
  where phone is not null and trim(phone) <> '';
create unique index if not exists loan_repayments_mpesa_reference_unique
  on public.loan_repayments (business_id, payment_reference)
  where payment_reference is not null
    and trim(payment_reference) <> ''
    and upper(payment_reference) <> 'IMPORT';

-- Speed indexes for daily operations and reports.
create index if not exists loan_staff_business_idx on public.loan_staff (business_id, is_active);
create index if not exists loan_clients_business_name_idx on public.loan_clients (business_id, full_name);
create index if not exists loan_applications_business_status_idx on public.loan_applications (business_id, status, created_at desc);
create index if not exists loans_business_status_idx on public.loans (business_id, status, created_at desc);
create index if not exists loans_client_idx on public.loans (client_id, status);
create index if not exists loans_officer_idx on public.loans (business_id, loan_officer_id);
create index if not exists schedules_business_due_idx on public.loan_schedules (business_id, due_date, status);
create index if not exists schedules_loan_idx on public.loan_schedules (loan_id, installment_no);
create index if not exists repayments_business_date_idx on public.loan_repayments (business_id, payment_date desc);
create index if not exists repayments_loan_idx on public.loan_repayments (loan_id, payment_date);
create index if not exists penalties_business_date_idx on public.loan_penalties (business_id, date_charged desc);
create index if not exists callback_pending_idx on public.mpesa_callback_queue (confirmed, created_at desc);
create index if not exists unmatched_business_idx on public.unmatched_payments (business_id, resolved, created_at desc);

-- Keep updated_at accurate.
do $$
declare table_name text;
begin
  foreach table_name in array array[
    'loan_staff','loan_settings','loan_clients','loan_products','loan_applications',
    'loans','loan_schedules','loan_repayments','loan_billing_cycles',
    'mpesa_callback_queue','unmatched_payments'
  ] loop
    execute format('drop trigger if exists set_updated_at on public.%I', table_name);
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', table_name);
  end loop;
end $$;

-- Resolve the logged-in user's business securely.
create or replace function public.current_patafix_business_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select business_id
  from public.loan_staff
  where auth_user_id = auth.uid() and is_active = true
  limit 1;
$$;

revoke all on function public.current_patafix_business_id() from public;
grant execute on function public.current_patafix_business_id() to anon, authenticated, service_role;

-- Enable row-level security on every business table.
alter table public.loan_staff enable row level security;
alter table public.loan_settings enable row level security;
alter table public.loan_clients enable row level security;
alter table public.loan_products enable row level security;
alter table public.loan_applications enable row level security;
alter table public.loans enable row level security;
alter table public.loan_schedules enable row level security;
alter table public.loan_repayments enable row level security;
alter table public.loan_penalties enable row level security;
alter table public.loan_follow_ups enable row level security;
alter table public.journal_entries enable row level security;
alter table public.loan_audit_log enable row level security;
alter table public.loan_billing_cycles enable row level security;
alter table public.mpesa_callback_queue enable row level security;
alter table public.unmatched_payments enable row level security;

-- A new business is provisioned only by the registration Edge Function.
-- Existing administrators can add staff only inside their own business.
drop policy if exists patafix_staff_select on public.loan_staff;
create policy patafix_staff_select on public.loan_staff for select to authenticated
using (auth_user_id = auth.uid() or business_id = public.current_patafix_business_id());
drop policy if exists patafix_staff_insert on public.loan_staff;
create policy patafix_staff_insert on public.loan_staff for insert to authenticated
with check (business_id = public.current_patafix_business_id());
drop policy if exists patafix_staff_update on public.loan_staff;
create policy patafix_staff_update on public.loan_staff for update to authenticated
using (auth_user_id = auth.uid() or business_id = public.current_patafix_business_id())
with check (business_id = public.current_patafix_business_id());
drop policy if exists patafix_staff_delete on public.loan_staff;
create policy patafix_staff_delete on public.loan_staff for delete to authenticated
using (business_id = public.current_patafix_business_id());

-- Apply the same business isolation to the remaining tables.
do $$
declare table_name text;
begin
  foreach table_name in array array[
    'loan_settings','loan_clients','loan_products','loan_applications','loans',
    'loan_schedules','loan_repayments','loan_penalties','loan_follow_ups',
    'journal_entries','loan_audit_log','loan_billing_cycles','mpesa_callback_queue',
    'unmatched_payments'
  ] loop
    execute format('drop policy if exists patafix_business_select on public.%I', table_name);
    execute format('drop policy if exists patafix_business_insert on public.%I', table_name);
    execute format('drop policy if exists patafix_business_update on public.%I', table_name);
    execute format('drop policy if exists patafix_business_delete on public.%I', table_name);
    execute format('create policy patafix_business_select on public.%I for select to authenticated using (business_id = public.current_patafix_business_id())', table_name);
    execute format('create policy patafix_business_insert on public.%I for insert to authenticated with check (business_id = public.current_patafix_business_id())', table_name);
    execute format('create policy patafix_business_update on public.%I for update to authenticated using (business_id = public.current_patafix_business_id()) with check (business_id = public.current_patafix_business_id())', table_name);
    execute format('create policy patafix_business_delete on public.%I for delete to authenticated using (business_id = public.current_patafix_business_id())', table_name);
  end loop;
end $$;

-- Storage buckets for compressed profile and asset photos.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('patafix-client-photos', 'patafix-client-photos', true, 524288, array['image/jpeg','image/png','image/webp']),
  ('patafix-client-assets', 'patafix-client-assets', true, 524288, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists patafix_photo_read on storage.objects;
create policy patafix_photo_read on storage.objects for select
using (bucket_id in ('patafix-client-photos','patafix-client-assets'));
drop policy if exists patafix_photo_insert on storage.objects;
create policy patafix_photo_insert on storage.objects for insert to authenticated
with check (bucket_id in ('patafix-client-photos','patafix-client-assets'));
drop policy if exists patafix_photo_update on storage.objects;
create policy patafix_photo_update on storage.objects for update to authenticated
using (bucket_id in ('patafix-client-photos','patafix-client-assets'))
with check (bucket_id in ('patafix-client-photos','patafix-client-assets'));
drop policy if exists patafix_photo_delete on storage.objects;
create policy patafix_photo_delete on storage.objects for delete to authenticated
using (bucket_id in ('patafix-client-photos','patafix-client-assets'));

-- Verification result: this final query should return 15 rows.
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name in (
    'loan_staff','loan_settings','loan_clients','loan_products','loan_applications',
    'loans','loan_schedules','loan_repayments','loan_penalties','loan_follow_ups',
    'journal_entries','loan_audit_log','loan_billing_cycles','mpesa_callback_queue',
    'unmatched_payments'
  )
order by table_name;
