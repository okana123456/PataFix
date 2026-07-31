-- Run once in the PataFix Supabase SQL Editor before deploying register-daraja.
-- Credentials are available only to backend functions using the service role.

alter table public.loan_settings
  add column if not exists daraja_credentials_saved boolean not null default false;

create table if not exists public.patafix_daraja_credentials (
  business_id text primary key,
  consumer_key text not null,
  consumer_secret text not null,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.patafix_daraja_credentials enable row level security;
revoke all on table public.patafix_daraja_credentials from anon, authenticated;
grant all on table public.patafix_daraja_credentials to service_role;

-- Preserve and migrate credentials that may already exist in legacy settings.
insert into public.patafix_daraja_credentials (business_id, consumer_key, consumer_secret)
select business_id, trim(mpesa_consumer_key), trim(mpesa_consumer_secret)
from public.loan_settings
where nullif(trim(mpesa_consumer_key), '') is not null
  and nullif(trim(mpesa_consumer_secret), '') is not null
on conflict (business_id) do nothing;

update public.loan_settings s
set daraja_credentials_saved = true
where exists (
  select 1
  from public.patafix_daraja_credentials c
  where c.business_id = s.business_id
);
