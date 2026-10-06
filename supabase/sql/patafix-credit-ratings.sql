begin;

create table if not exists public.patafix_credit_profiles (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  client_id uuid not null references public.loan_clients(id) on delete cascade,
  approved_limit numeric(14,2) not null default 0,
  credit_score numeric(14,2) not null default 0,
  rating_status text not null default 'new'
    check (rating_status in ('new','good','watchlist','zero')),
  current_arrears_days integer not null default 0,
  max_days_overdue integer not null default 0,
  clean_loans_completed integer not null default 0,
  has_late_history boolean not null default false,
  last_reason text,
  last_calculated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, client_id)
);

create table if not exists public.patafix_credit_events (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  client_id uuid not null references public.loan_clients(id) on delete cascade,
  loan_id uuid references public.loans(id) on delete set null,
  event_type text not null,
  event_date date not null default current_date,
  previous_score numeric(14,2) not null default 0,
  new_score numeric(14,2) not null default 0,
  amount_change numeric(14,2) not null default 0,
  days_overdue integer not null default 0,
  reason text not null,
  source_key text not null,
  created_at timestamptz not null default now(),
  unique (business_id, source_key)
);

create index if not exists patafix_credit_profiles_business_status_idx
  on public.patafix_credit_profiles (business_id, rating_status, credit_score desc);
create index if not exists patafix_credit_events_client_date_idx
  on public.patafix_credit_events (business_id, client_id, event_date desc, created_at desc);

drop trigger if exists set_updated_at on public.patafix_credit_profiles;
create trigger set_updated_at before update on public.patafix_credit_profiles
for each row execute function public.set_updated_at();

alter table public.patafix_credit_profiles enable row level security;
alter table public.patafix_credit_events enable row level security;

grant select on public.patafix_credit_profiles to authenticated;
grant select on public.patafix_credit_events to authenticated;

do $$
declare v_table text;
begin
  foreach v_table in array array['patafix_credit_profiles','patafix_credit_events'] loop
    execute format('drop policy if exists patafix_business_select on public.%I',v_table);
    execute format('drop policy if exists patafix_business_insert on public.%I',v_table);
    execute format('drop policy if exists patafix_business_update on public.%I',v_table);
    execute format('drop policy if exists patafix_business_delete on public.%I',v_table);
    execute format('create policy patafix_business_select on public.%I for select to authenticated using (business_id = public.current_patafix_business_id())',v_table);
    execute format('create policy patafix_business_insert on public.%I for insert to authenticated with check (business_id = public.current_patafix_business_id())',v_table);
    execute format('create policy patafix_business_update on public.%I for update to authenticated using (business_id = public.current_patafix_business_id()) with check (business_id = public.current_patafix_business_id())',v_table);
    execute format('create policy patafix_business_delete on public.%I for delete to authenticated using (business_id = public.current_patafix_business_id())',v_table);
  end loop;
end $$;

create or replace function public.patafix_refresh_credit_scores_for_business(p_business_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
  v_client record;
  v_loan record;
  v_profile public.patafix_credit_profiles%rowtype;
  v_latest_loan_id uuid;
  v_latest_principal numeric(14,2);
  v_schedule_count integer;
  v_all_paid boolean;
  v_loan_max_late integer;
  v_current_late integer;
  v_lifetime_late integer;
  v_previous_score numeric(14,2);
  v_new_limit numeric(14,2);
  v_awards integer := 0;
  v_zero_count integer := 0;
begin
  if nullif(btrim(p_business_id),'') is null then
    raise exception 'Business is required for credit score refresh.';
  end if;

  perform pg_advisory_xact_lock(hashtext('patafix-credit:'||p_business_id));

  for v_client in
    select c.id
    from public.loan_clients c
    where c.business_id = p_business_id
  loop
    select l.id,coalesce(l.principal_amount,0)
      into v_latest_loan_id,v_latest_principal
    from public.loans l
    where l.business_id=p_business_id and l.client_id=v_client.id
    order by case when l.status='active' then 0 else 1 end,
             coalesce(l.disbursement_date,l.created_at::date) desc,
             l.created_at desc
    limit 1;

    v_latest_principal := coalesce(v_latest_principal,0);

    insert into public.patafix_credit_profiles (
      business_id,client_id,approved_limit,credit_score,rating_status,last_reason
    ) values (
      p_business_id,v_client.id,v_latest_principal,v_latest_principal,
      case when v_latest_loan_id is null then 'new' else 'good' end,
      case when v_latest_loan_id is null then 'No approved loan yet' else 'Current approved loan amount' end
    )
    on conflict (business_id,client_id) do nothing;

    select * into v_profile
    from public.patafix_credit_profiles
    where business_id=p_business_id and client_id=v_client.id
    for update;

    if v_latest_loan_id is not null and v_latest_principal>v_profile.approved_limit then
      v_previous_score:=v_profile.approved_limit;
      update public.patafix_credit_profiles
      set approved_limit=v_latest_principal,
          last_reason='Approved limit aligned to latest approved loan'
      where id=v_profile.id;

      insert into public.patafix_credit_events (
        business_id,client_id,loan_id,event_type,event_date,previous_score,new_score,
        amount_change,days_overdue,reason,source_key
      ) values (
        p_business_id,v_client.id,v_latest_loan_id,'approved_limit_sync',v_today,
        v_previous_score,v_latest_principal,v_latest_principal-v_previous_score,0,
        'Approved limit aligned to latest approved loan','approved-limit:'||v_latest_loan_id::text
      ) on conflict (business_id,source_key) do nothing;
    end if;

    for v_loan in
      select l.id,l.principal_amount,l.loan_no
      from public.loans l
      where l.business_id=p_business_id
        and l.client_id=v_client.id
        and l.status='completed'
        and not exists (
          select 1 from public.patafix_credit_events e
          where e.business_id=p_business_id
            and e.source_key='credit-loan:'||l.id::text
        )
      order by coalesce(l.maturity_date,l.disbursement_date),l.created_at
    loop
      select
        count(*)::integer,
        coalesce(bool_and(coalesce(s.total_paid,0)>=coalesce(s.total_due,0)-0.01),false),
        coalesce(max(greatest(0,
          coalesce((s.paid_at at time zone 'Africa/Nairobi')::date,v_today)-s.due_date
        )),0)::integer
      into v_schedule_count,v_all_paid,v_loan_max_late
      from public.loan_schedules s
      where s.loan_id=v_loan.id and s.status<>'restructured';

      select * into v_profile
      from public.patafix_credit_profiles
      where business_id=p_business_id and client_id=v_client.id
      for update;

      if v_schedule_count>0 and v_all_paid and v_loan_max_late<=3 then
        v_previous_score:=v_profile.approved_limit;
        v_new_limit:=greatest(v_profile.approved_limit,coalesce(v_loan.principal_amount,0))+2000;
        update public.patafix_credit_profiles
        set approved_limit=v_new_limit,
            clean_loans_completed=clean_loans_completed+1,
            max_days_overdue=greatest(max_days_overdue,v_loan_max_late),
            last_reason='KES 2,000 added after clean completion of loan '||coalesce(v_loan.loan_no,'')
        where id=v_profile.id;
        insert into public.patafix_credit_events (
          business_id,client_id,loan_id,event_type,event_date,previous_score,new_score,
          amount_change,days_overdue,reason,source_key
        ) values (
          p_business_id,v_client.id,v_loan.id,'clean_completion_bonus',v_today,
          v_previous_score,v_new_limit,2000,v_loan_max_late,
          'Loan '||coalesce(v_loan.loan_no,'')||' completed without exceeding three days in arrears',
          'credit-loan:'||v_loan.id::text
        );
        v_awards:=v_awards+1;
      else
        update public.patafix_credit_profiles
        set has_late_history=has_late_history or v_loan_max_late>3,
            max_days_overdue=greatest(max_days_overdue,v_loan_max_late),
            last_reason=case when v_loan_max_late>3
              then 'Loan '||coalesce(v_loan.loan_no,'')||' exceeded three days in arrears; no completion bonus'
              else last_reason end
        where id=v_profile.id;
        insert into public.patafix_credit_events (
          business_id,client_id,loan_id,event_type,event_date,previous_score,new_score,
          amount_change,days_overdue,reason,source_key
        ) values (
          p_business_id,v_client.id,v_loan.id,'completion_no_bonus',v_today,
          v_profile.approved_limit,v_profile.approved_limit,0,v_loan_max_late,
          case when v_schedule_count=0 then 'No repayment schedule was available for clean-completion scoring'
               when not v_all_paid then 'Loan schedule was not fully paid'
               else 'Loan exceeded three days in arrears' end,
          'credit-loan:'||v_loan.id::text
        );
      end if;
    end loop;

    select coalesce(max(v_today-s.due_date),0)::integer
      into v_current_late
    from public.loan_schedules s
    join public.loans l on l.id=s.loan_id
    where l.business_id=p_business_id
      and l.client_id=v_client.id
      and l.status='active'
      and s.status<>'restructured'
      and coalesce(s.total_due,0)-coalesce(s.total_paid,0)>0.01
      and s.due_date<v_today-3;

    select coalesce(max(greatest(0,
      coalesce((s.paid_at at time zone 'Africa/Nairobi')::date,v_today)-s.due_date
    )),0)::integer
      into v_lifetime_late
    from public.loan_schedules s
    join public.loans l on l.id=s.loan_id
    where l.business_id=p_business_id
      and l.client_id=v_client.id
      and s.status<>'restructured';

    select * into v_profile
    from public.patafix_credit_profiles
    where business_id=p_business_id and client_id=v_client.id
    for update;

    if v_current_late>3 then
      if v_profile.rating_status<>'zero' then
        insert into public.patafix_credit_events (
          business_id,client_id,event_type,event_date,previous_score,new_score,
          amount_change,days_overdue,reason,source_key
        ) values (
          p_business_id,v_client.id,'arrears_zero',v_today,v_profile.credit_score,0,
          -v_profile.credit_score,v_current_late,
          'Credit score reduced to zero after more than three days in arrears',
          'arrears-zero:'||v_client.id::text||':'||v_today::text
        ) on conflict (business_id,source_key) do nothing;
      end if;
      update public.patafix_credit_profiles
      set credit_score=0,rating_status='zero',current_arrears_days=v_current_late,
          max_days_overdue=greatest(max_days_overdue,v_lifetime_late,v_current_late),
          has_late_history=true,
          last_reason='Currently '||v_current_late||' days in arrears; score is zero',
          last_calculated_at=now()
      where id=v_profile.id;
      v_zero_count:=v_zero_count+1;
    else
      if v_profile.rating_status='zero' then
        insert into public.patafix_credit_events (
          business_id,client_id,event_type,event_date,previous_score,new_score,
          amount_change,days_overdue,reason,source_key
        ) values (
          p_business_id,v_client.id,'arrears_cleared',v_today,0,v_profile.approved_limit,
          v_profile.approved_limit,0,
          'Arrears cleared; approved limit restored with Watchlist status',
          'arrears-cleared:'||v_client.id::text||':'||v_today::text
        ) on conflict (business_id,source_key) do nothing;
      end if;
      update public.patafix_credit_profiles
      set credit_score=approved_limit,current_arrears_days=0,
          max_days_overdue=greatest(max_days_overdue,v_lifetime_late),
          has_late_history=has_late_history or v_lifetime_late>3,
          rating_status=case
            when approved_limit<=0 then 'new'
            when has_late_history or v_lifetime_late>3 then 'watchlist'
            else 'good' end,
          last_reason=case
            when approved_limit<=0 then 'No approved loan yet'
            when has_late_history or v_lifetime_late>3 then 'No current arrears; prior late-payment history retained'
            else coalesce(last_reason,'Repayment history is within the three-day allowance') end,
          last_calculated_at=now()
      where id=v_profile.id;
    end if;
  end loop;

  return jsonb_build_object(
    'ok',true,'business_id',p_business_id,'bonuses_awarded',v_awards,
    'clients_at_zero',v_zero_count,'calculated_at',now()
  );
end;
$$;

create or replace function public.patafix_refresh_credit_scores()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_business_id text := public.current_patafix_business_id();
begin
  if v_business_id is null then
    raise exception 'No active PataFix staff account was found.';
  end if;
  return public.patafix_refresh_credit_scores_for_business(v_business_id);
end;
$$;

revoke all on function public.patafix_refresh_credit_scores_for_business(text) from public;
revoke all on function public.patafix_refresh_credit_scores() from public;
grant execute on function public.patafix_refresh_credit_scores() to authenticated,service_role;
grant execute on function public.patafix_refresh_credit_scores_for_business(text) to service_role;

-- Existing clients start at their latest/current approved principal amount.
insert into public.patafix_credit_profiles (
  business_id,client_id,approved_limit,credit_score,rating_status,last_reason
)
select
  c.business_id,c.id,coalesce(latest.principal_amount,0),coalesce(latest.principal_amount,0),
  case when latest.id is null then 'new' else 'good' end,
  case when latest.id is null then 'No approved loan yet' else 'Existing client baseline: current approved loan amount' end
from public.loan_clients c
left join lateral (
  select l.id,l.principal_amount
  from public.loans l
  where l.business_id=c.business_id and l.client_id=c.id
  order by case when l.status='active' then 0 else 1 end,
           coalesce(l.disbursement_date,l.created_at::date) desc,l.created_at desc
  limit 1
) latest on true
where c.business_id='BIZ-58D22296'
on conflict (business_id,client_id) do nothing;

insert into public.patafix_credit_events (
  business_id,client_id,event_type,event_date,previous_score,new_score,
  amount_change,days_overdue,reason,source_key
)
select
  p.business_id,p.client_id,'baseline',(now() at time zone 'Africa/Nairobi')::date,
  0,p.approved_limit,p.approved_limit,0,
  'Existing client baseline set to the current approved loan amount',
  'credit-baseline:'||p.client_id::text
from public.patafix_credit_profiles p
where p.business_id='BIZ-58D22296'
on conflict (business_id,source_key) do nothing;

-- Mark already-completed loans as historically reviewed without granting retroactive bonuses.
insert into public.patafix_credit_events (
  business_id,client_id,loan_id,event_type,event_date,previous_score,new_score,
  amount_change,days_overdue,reason,source_key
)
select
  l.business_id,l.client_id,l.id,'historical_baseline',
  coalesce(l.maturity_date,l.disbursement_date,(now() at time zone 'Africa/Nairobi')::date),
  p.approved_limit,p.approved_limit,0,coalesce(stats.max_late,0),
  'Existing completed loan recorded at rollout; no retroactive KES 2,000 bonus',
  'credit-loan:'||l.id::text
from public.loans l
join public.patafix_credit_profiles p
  on p.business_id=l.business_id and p.client_id=l.client_id
left join lateral (
  select max(greatest(0,
    coalesce((s.paid_at at time zone 'Africa/Nairobi')::date,(now() at time zone 'Africa/Nairobi')::date)-s.due_date
  ))::integer as max_late
  from public.loan_schedules s where s.loan_id=l.id and s.status<>'restructured'
) stats on true
where l.business_id='BIZ-58D22296' and l.status='completed'
on conflict (business_id,source_key) do nothing;

select public.patafix_refresh_credit_scores_for_business('BIZ-58D22296');

commit;

select
  c.full_name as client,
  c.id_number,
  p.approved_limit,
  p.credit_score,
  p.rating_status,
  p.current_arrears_days,
  p.max_days_overdue,
  p.clean_loans_completed,
  p.last_reason
from public.patafix_credit_profiles p
join public.loan_clients c on c.id=p.client_id
where p.business_id='BIZ-58D22296'
order by p.rating_status desc,c.full_name;
