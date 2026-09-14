-- Product fields required for configurable PataFix loan products.
-- Safe to run more than once.

begin;

alter table public.loan_products
  add column if not exists registration_fee numeric(14,2) not null default 0,
  add column if not exists processing_fee_type text not null default 'percent',
  add column if not exists processing_fee_value numeric(14,4) not null default 0,
  add column if not exists repayment_frequency text not null default 'weekly',
  add column if not exists term_unit text not null default 'weeks';

update public.loan_products
set processing_fee_type='percent',
    processing_fee_value=processing_fee_pct
where processing_fee_value=0 and processing_fee_pct<>0;

-- Preserve the existing approved PataFix products while moving their rules
-- into the database so later edits apply everywhere in the system.
update public.loan_products
set registration_fee=case upper(trim(name))
      when 'INUA BIZ' then 200 when 'KUZA' then 300
      when 'NAWIRI' then 400 when 'KOMANZA' then 400 else registration_fee end,
    processing_fee_type=case when upper(trim(name))='INUA BIZ' then 'flat' else 'percent' end,
    processing_fee_value=case upper(trim(name))
      when 'INUA BIZ' then 500 when 'KUZA' then 5
      when 'NAWIRI' then 6 when 'KOMANZA' then 10 else processing_fee_value end,
    repayment_frequency=case when upper(trim(name))='KOMANZA' then 'biweekly' else 'weekly' end,
    term_unit='weeks'
where upper(trim(name)) in ('INUA BIZ','KUZA','NAWIRI','KOMANZA');

insert into public.loan_products (
  business_id,name,description,min_amount,max_amount,interest_rate,
  interest_type,interest_period,min_term_weeks,max_term_weeks,
  processing_fee_pct,processing_fee_type,processing_fee_value,
  registration_fee,repayment_frequency,term_unit,
  late_penalty_pct,grace_period_days,requires_guarantor,is_active
)
select
  s.business_id,'UWEZO LOAN',
  'KES 15,000-50,000 | choose 1, 2 or 3 months | 12% monthly | 8% processing fee | KES 500 registration fee | monthly payments',
  15000,50000,12,'flat','monthly',4,12,8,'percent',8,500,'monthly','months',5,3,true,true
from public.loan_settings s
where not exists (
  select 1 from public.loan_products p
  where p.business_id=s.business_id and lower(trim(p.name))='uwezo loan'
);

update public.loan_products
set description='KES 15,000-50,000 | choose 1, 2 or 3 months | 12% monthly | 8% processing fee | KES 500 registration fee | monthly payments',
    min_amount=15000,max_amount=50000,interest_rate=12,
    interest_type='flat',interest_period='monthly',
    min_term_weeks=4,max_term_weeks=12,
    processing_fee_pct=8,processing_fee_type='percent',processing_fee_value=8,
    registration_fee=500,repayment_frequency='monthly',term_unit='months',
    is_active=true,updated_at=now()
where lower(trim(name))='uwezo loan';

commit;

select name,min_amount,max_amount,interest_rate,interest_period,
       min_term_weeks,max_term_weeks,term_unit,repayment_frequency,
       processing_fee_type,processing_fee_value,registration_fee,is_active
from public.loan_products
where lower(trim(name))='uwezo loan';
