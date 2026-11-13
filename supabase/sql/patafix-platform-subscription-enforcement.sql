-- PataFix platform Phase 3: package limits and subscription access status.
-- Existing legacy businesses keep their current billing flow because their
-- platform settings do not enable managed enforcement.

begin;

alter table public.patafix_platform_plans
  add column if not exists grace_days integer not null default 3
    check (grace_days between 0 and 30);

alter table public.loan_billing_cycles
  add column if not exists metadata jsonb not null default '{}'::jsonb;

update public.patafix_platform_plans
set grace_days = 3,
    updated_at = now()
where code in ('starter','growth','multi_branch');

create or replace function public.patafix_vendor_subscription_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_business_id text := public.current_patafix_business_id();
  v_business public.patafix_platform_businesses%rowtype;
  v_plan public.patafix_platform_plans%rowtype;
  v_enforced boolean := false;
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
  v_month date := date_trunc('month',(now() at time zone 'Africa/Nairobi'))::date;
  v_grace_deadline date;
  v_amount numeric(14,2);
  v_paid record;
begin
  if v_business_id is null then
    return jsonb_build_object('managed',false,'allowed',false,'state','no_business');
  end if;

  select * into v_business
  from public.patafix_platform_businesses
  where business_id = v_business_id;

  if not found then
    return jsonb_build_object(
      'managed',false,'allowed',true,'state','legacy',
      'business_id',v_business_id
    );
  end if;

  select * into v_plan
  from public.patafix_platform_plans
  where id = v_business.plan_id;

  if coalesce(v_business.settings,'{}'::jsonb) @> '{"demo_mode":true}'::jsonb then
    return jsonb_build_object(
      'managed',true,'allowed',true,'locked',false,'reminder',false,
      'state','demo','business_id',v_business_id,'amount',0
    );
  end if;

  begin
    v_enforced := coalesce((v_business.settings ->> 'enforcement_enabled')::boolean,false);
  exception when invalid_text_representation then
    v_enforced := false;
  end;

  v_amount := coalesce(v_business.monthly_fee_override,v_plan.monthly_fee,3000);
  v_grace_deadline := (v_month + make_interval(days => greatest(coalesce(v_plan.grace_days,3) - 1,-1)))::date;

  if not v_enforced then
    return jsonb_build_object(
      'managed',false,'allowed',true,'state','legacy',
      'business_id',v_business_id,'amount',v_amount
    );
  end if;

  if v_business.status in ('suspended','closed') then
    return jsonb_build_object(
      'managed',true,'allowed',false,'locked',true,'state',v_business.status,
      'business_id',v_business_id,'amount',v_amount
    );
  end if;

  if v_business.onboarding_payment_status not in ('paid','waived') then
    return jsonb_build_object(
      'managed',true,'allowed',false,'locked',true,'state','onboarding_pending',
      'business_id',v_business_id,'amount',v_business.onboarding_fee
    );
  end if;

  if v_business.subscription_start_date is null
     or v_today < v_business.subscription_start_date then
    return jsonb_build_object(
      'managed',true,'allowed',true,'locked',false,'reminder',false,
      'state','onboarding_period','business_id',v_business_id,
      'amount',v_amount,'subscription_start_date',v_business.subscription_start_date
    );
  end if;

  select status,paid_at,paid_until,receipt_number,phone,billing_month,amount
    into v_paid
  from public.loan_billing_cycles
  where business_id = v_business_id
    and status = 'paid'
    and (
      billing_month = v_month
      or (billing_month < v_month and paid_until >= v_today)
    )
  order by paid_until desc nulls last,paid_at desc nulls last
  limit 1;

  if found then
    return jsonb_build_object(
      'managed',true,'allowed',true,'locked',false,'reminder',false,
      'state','paid','business_id',v_business_id,'amount',v_amount,
      'billing_month',v_month,'paid_at',v_paid.paid_at,
      'paid_until',v_paid.paid_until,'receipt_number',v_paid.receipt_number,
      'phone',v_paid.phone
    );
  end if;

  return jsonb_build_object(
    'managed',true,
    'allowed',v_today <= v_grace_deadline,
    'locked',v_today > v_grace_deadline,
    'reminder',v_today >= v_month,
    'state',case when v_today > v_grace_deadline then 'overdue' else 'due' end,
    'business_id',v_business_id,
    'amount',v_amount,
    'billing_month',v_month,
    'due_date',v_month,
    'grace_deadline',v_grace_deadline,
    'subscription_start_date',v_business.subscription_start_date
  );
end;
$$;

revoke all on function public.patafix_vendor_subscription_status() from public;
grant execute on function public.patafix_vendor_subscription_status() to authenticated,service_role;

create or replace function public.patafix_enforce_client_package_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer;
  v_enforced boolean := false;
  v_count integer;
begin
  select coalesce(b.client_limit_override,p.max_clients),
         coalesce((b.settings ->> 'enforcement_enabled')::boolean,false)
    into v_limit,v_enforced
  from public.patafix_platform_businesses b
  join public.patafix_platform_plans p on p.id=b.plan_id
  where b.business_id=new.business_id;

  if not coalesce(v_enforced,false) or v_limit is null then return new; end if;
  perform pg_advisory_xact_lock(hashtext('patafix-client-limit:' || new.business_id));
  select count(*) into v_count
  from public.loan_clients
  where business_id=new.business_id and status <> 'deleted';
  if v_count >= v_limit then
    raise exception 'Client limit of % reached for this subscription package',v_limit;
  end if;
  return new;
exception when invalid_text_representation then
  return new;
end;
$$;

drop trigger if exists patafix_enforce_client_package_limit on public.loan_clients;
create trigger patafix_enforce_client_package_limit
before insert on public.loan_clients
for each row execute function public.patafix_enforce_client_package_limit();

create or replace function public.patafix_enforce_branch_package_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer;
  v_enforced boolean := false;
  v_count integer;
begin
  if coalesce(new.status,'active') <> 'active' then
    return new;
  end if;
  if tg_op='UPDATE' then
    if coalesce(old.status,'active')='active' then return new; end if;
  end if;

  select coalesce(b.branch_limit_override,p.max_branches),
         coalesce((b.settings ->> 'enforcement_enabled')::boolean,false)
    into v_limit,v_enforced
  from public.patafix_platform_businesses b
  join public.patafix_platform_plans p on p.id=b.plan_id
  where b.business_id=new.business_id;

  if not coalesce(v_enforced,false) or v_limit is null then return new; end if;
  perform pg_advisory_xact_lock(hashtext('patafix-branch-limit:' || new.business_id));
  select count(*) into v_count
  from public.patafix_branches
  where business_id=new.business_id and status='active';
  if v_count >= v_limit then
    raise exception 'Branch limit of % reached for this subscription package',v_limit;
  end if;
  return new;
exception when invalid_text_representation then
  return new;
end;
$$;

drop trigger if exists patafix_enforce_branch_package_limit on public.patafix_branches;
create trigger patafix_enforce_branch_package_limit
before insert or update of status on public.patafix_branches
for each row execute function public.patafix_enforce_branch_package_limit();

commit;

select
  'PataFix managed subscription enforcement ready' as status,
  (select monthly_fee from public.patafix_platform_plans where code='starter') as starter_monthly_fee,
  (select max_clients from public.patafix_platform_plans where code='starter') as starter_client_limit,
  (select grace_days from public.patafix_platform_plans where code='starter') as grace_days,
  coalesce((
    select (settings ->> 'enforcement_enabled')::boolean
    from public.patafix_platform_businesses
    where business_id='BIZ-58D22296'
  ),false) as existing_patafix_managed,
  (select count(*) from public.patafix_platform_businesses
   where coalesce((settings ->> 'enforcement_enabled')::boolean,false)) as managed_businesses;
