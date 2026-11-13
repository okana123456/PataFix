-- PataFix SaaS control-plane foundation.
-- Additive only: this migration does not change the live vendor application,
-- existing Daraja callbacks, tenant RLS policies, billing, loans or repayments.

begin;

create extension if not exists pgcrypto;

create table if not exists public.patafix_platform_admins (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.patafix_platform_plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  description text,
  onboarding_fee numeric(14,2) not null default 7500 check (onboarding_fee >= 0),
  monthly_fee numeric(14,2) not null default 3000 check (monthly_fee >= 0),
  max_clients integer check (max_clients is null or max_clients > 0),
  max_branches integer check (max_branches is null or max_branches > 0),
  features jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  is_public boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (code = lower(code) and code ~ '^[a-z0-9_]+$')
);

create table if not exists public.patafix_platform_businesses (
  business_id text primary key,
  display_name text not null,
  slug text unique,
  status text not null default 'pending_onboarding'
    check (status in ('pending_onboarding','trial','active','past_due','suspended','closed')),
  plan_id uuid references public.patafix_platform_plans(id) on delete restrict,
  onboarding_fee numeric(14,2) not null default 7500 check (onboarding_fee >= 0),
  onboarding_payment_status text not null default 'pending'
    check (onboarding_payment_status in ('pending','paid','waived','refunded')),
  onboarding_paid_at timestamptz,
  subscription_start_date date,
  monthly_fee_override numeric(14,2) check (monthly_fee_override is null or monthly_fee_override >= 0),
  client_limit_override integer check (client_limit_override is null or client_limit_override > 0),
  branch_limit_override integer check (branch_limit_override is null or branch_limit_override > 0),
  branding jsonb not null default '{}'::jsonb,
  settings jsonb not null default '{}'::jsonb,
  notes text,
  created_by uuid references public.patafix_platform_admins(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.patafix_platform_memberships (
  id uuid primary key default gen_random_uuid(),
  business_id text not null references public.patafix_platform_businesses(business_id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  staff_id uuid references public.loan_staff(id) on delete set null,
  role text not null default 'staff',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, auth_user_id)
);

create table if not exists public.patafix_platform_feature_overrides (
  id uuid primary key default gen_random_uuid(),
  business_id text not null references public.patafix_platform_businesses(business_id) on delete cascade,
  feature_key text not null,
  enabled boolean not null,
  config jsonb not null default '{}'::jsonb,
  updated_by uuid references public.patafix_platform_admins(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, feature_key),
  check (feature_key = lower(feature_key) and feature_key ~ '^[a-z0-9_]+$')
);

create table if not exists public.patafix_platform_payments (
  id uuid primary key default gen_random_uuid(),
  business_id text not null references public.patafix_platform_businesses(business_id) on delete cascade,
  payment_type text not null check (payment_type in ('onboarding','subscription','upgrade','credit','refund','manual')),
  billing_month date,
  amount numeric(14,2) not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending','paid','failed','refunded','cancelled')),
  payment_method text,
  payment_reference text,
  phone text,
  paid_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, payment_type, payment_reference)
);

create table if not exists public.patafix_platform_audit_log (
  id uuid primary key default gen_random_uuid(),
  platform_admin_id uuid references public.patafix_platform_admins(id) on delete set null,
  business_id text references public.patafix_platform_businesses(business_id) on delete set null,
  action text not null,
  entity_type text,
  entity_id text,
  old_value jsonb,
  new_value jsonb,
  created_at timestamptz not null default now()
);

create index if not exists patafix_platform_businesses_status_idx
  on public.patafix_platform_businesses(status, plan_id);
create index if not exists patafix_platform_memberships_user_idx
  on public.patafix_platform_memberships(auth_user_id, is_active);
create index if not exists patafix_platform_payments_business_idx
  on public.patafix_platform_payments(business_id, created_at desc);
create index if not exists patafix_platform_audit_business_idx
  on public.patafix_platform_audit_log(business_id, created_at desc);

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'patafix_platform_admins','patafix_platform_plans','patafix_platform_businesses',
    'patafix_platform_memberships','patafix_platform_feature_overrides','patafix_platform_payments'
  ] loop
    execute format('drop trigger if exists set_updated_at on public.%I', v_table);
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', v_table);
  end loop;
end $$;

create or replace function public.patafix_is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.patafix_platform_admins a
    where a.auth_user_id = auth.uid()
      and a.is_active = true
  );
$$;

revoke all on function public.patafix_is_platform_admin() from public;
grant execute on function public.patafix_is_platform_admin() to authenticated, service_role;

create or replace function public.patafix_business_feature_enabled(
  p_business_id text,
  p_feature_key text
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_enabled boolean;
  v_plan_features jsonb;
begin
  if not public.patafix_is_platform_admin()
     and p_business_id <> public.current_patafix_business_id() then
    raise exception 'Business access denied';
  end if;

  select o.enabled into v_enabled
  from public.patafix_platform_feature_overrides o
  where o.business_id = p_business_id
    and o.feature_key = lower(trim(p_feature_key));

  if found then return v_enabled; end if;

  select p.features into v_plan_features
  from public.patafix_platform_businesses b
  join public.patafix_platform_plans p on p.id = b.plan_id
  where b.business_id = p_business_id;

  return coalesce((v_plan_features ->> lower(trim(p_feature_key)))::boolean, false);
exception when invalid_text_representation then
  return false;
end;
$$;

revoke all on function public.patafix_business_feature_enabled(text,text) from public;
grant execute on function public.patafix_business_feature_enabled(text,text) to authenticated, service_role;

insert into public.patafix_platform_plans
  (code,name,description,onboarding_fee,monthly_fee,max_clients,max_branches,features,is_active,is_public,sort_order)
values
  ('starter','Starter','Single-branch package for up to 1,000 clients',7500,3000,1000,1,
   '{"branches":false,"advanced_accounting":false,"company_assets":false,"expenses":true}'::jsonb,true,false,10),
  ('growth','Growth','Growing lender package',7500,5000,300,3,
   '{"branches":true,"advanced_accounting":true,"company_assets":true,"expenses":true}'::jsonb,true,false,20),
  ('multi_branch','Multi-Branch','Advanced multi-branch lender package',7500,7500,null,20,
   '{"branches":true,"advanced_accounting":true,"company_assets":true,"expenses":true}'::jsonb,true,false,30)
on conflict (code) do update set
  name=excluded.name,
  description=excluded.description,
  onboarding_fee=excluded.onboarding_fee,
  monthly_fee=excluded.monthly_fee,
  max_clients=excluded.max_clients,
  max_branches=excluded.max_branches,
  features=excluded.features,
  updated_at=now();

-- Register all existing businesses without altering their operational records.
insert into public.patafix_platform_businesses (
  business_id,display_name,slug,status,plan_id,onboarding_fee,
  onboarding_payment_status,monthly_fee_override,settings,notes
)
select
  s.business_id,
  s.company_name,
  lower(regexp_replace(s.business_id,'[^a-zA-Z0-9]+','-','g')),
  'active',
  (select id from public.patafix_platform_plans where code='multi_branch'),
  7500,
  'waived',
  case when s.business_id='BIZ-58D22296' then 7500 else null end,
  jsonb_build_object('legacy_business',true,'vendor_app_unchanged',true),
  'Imported automatically as an existing live business. No enforcement enabled.'
from public.loan_settings s
on conflict (business_id) do nothing;

insert into public.patafix_platform_memberships
  (business_id,auth_user_id,staff_id,role,is_active)
select s.business_id,s.auth_user_id,s.id,s.role,s.is_active
from public.loan_staff s
join public.patafix_platform_businesses b on b.business_id=s.business_id
where s.auth_user_id is not null
on conflict (business_id,auth_user_id) do update set
  staff_id=excluded.staff_id,
  role=excluded.role,
  is_active=excluded.is_active,
  updated_at=now();

alter table public.patafix_platform_admins enable row level security;
alter table public.patafix_platform_plans enable row level security;
alter table public.patafix_platform_businesses enable row level security;
alter table public.patafix_platform_memberships enable row level security;
alter table public.patafix_platform_feature_overrides enable row level security;
alter table public.patafix_platform_payments enable row level security;
alter table public.patafix_platform_audit_log enable row level security;

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'patafix_platform_admins','patafix_platform_plans','patafix_platform_businesses',
    'patafix_platform_feature_overrides','patafix_platform_payments','patafix_platform_audit_log'
  ] loop
    execute format('drop policy if exists patafix_platform_admin_select on public.%I',v_table);
    execute format('drop policy if exists patafix_platform_admin_insert on public.%I',v_table);
    execute format('drop policy if exists patafix_platform_admin_update on public.%I',v_table);
    execute format('drop policy if exists patafix_platform_admin_delete on public.%I',v_table);
    execute format('create policy patafix_platform_admin_select on public.%I for select to authenticated using (public.patafix_is_platform_admin())',v_table);
    execute format('create policy patafix_platform_admin_insert on public.%I for insert to authenticated with check (public.patafix_is_platform_admin())',v_table);
    execute format('create policy patafix_platform_admin_update on public.%I for update to authenticated using (public.patafix_is_platform_admin()) with check (public.patafix_is_platform_admin())',v_table);
    execute format('create policy patafix_platform_admin_delete on public.%I for delete to authenticated using (public.patafix_is_platform_admin())',v_table);
  end loop;
end $$;

drop policy if exists patafix_platform_membership_select on public.patafix_platform_memberships;
create policy patafix_platform_membership_select
on public.patafix_platform_memberships for select to authenticated
using (auth_user_id=auth.uid() or public.patafix_is_platform_admin());
drop policy if exists patafix_platform_membership_manage on public.patafix_platform_memberships;
create policy patafix_platform_membership_manage
on public.patafix_platform_memberships for all to authenticated
using (public.patafix_is_platform_admin())
with check (public.patafix_is_platform_admin());

grant select,insert,update,delete on public.patafix_platform_admins to authenticated;
grant select,insert,update,delete on public.patafix_platform_plans to authenticated;
grant select,insert,update,delete on public.patafix_platform_businesses to authenticated;
grant select,insert,update,delete on public.patafix_platform_memberships to authenticated;
grant select,insert,update,delete on public.patafix_platform_feature_overrides to authenticated;
grant select,insert,update,delete on public.patafix_platform_payments to authenticated;
grant select,insert,update,delete on public.patafix_platform_audit_log to authenticated;

commit;

select
  'PataFix platform control plane ready' as status,
  (select count(*) from public.patafix_platform_plans) as plans,
  (select count(*) from public.patafix_platform_businesses) as registered_businesses,
  (select count(*) from public.patafix_platform_memberships) as memberships,
  (select count(*) from public.patafix_platform_admins) as platform_admins;
