alter table public.loan_applications
  add column if not exists guarantor_name text,
  add column if not exists guarantor_phone text,
  add column if not exists guarantor_relationship text;

create index if not exists loan_applications_guarantor_phone_idx
  on public.loan_applications (business_id, guarantor_phone);
