-- Install the reusable demo reset and seed demoloan08@gmail.com.
-- The reset is restricted to businesses explicitly marked with demo_mode=true.

begin;

create or replace function public.patafix_reset_demo_business(p_business_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business_id text := p_business_id;
  v_admin_id uuid;
  v_admin_email text;
  v_display_name text;
  v_product_id uuid;
  v_officer_id uuid;
  v_client_id uuid;
  v_application_id uuid;
  v_loan_id uuid;
  v_principal numeric(14,2);
  v_interest numeric(14,2);
  v_total numeric(14,2);
  v_installment numeric(14,2);
  v_paid_count integer;
  v_total_paid numeric(14,2);
  v_outstanding numeric(14,2);
  v_arrears numeric(14,2);
  v_disbursed date;
  v_first_due date;
  v_due date;
  v_maturity date;
  v_status text;
  v_branch text;
  v_names text[] := array[
    'Amina Hassan','Brian Otieno','Carol Wanjiku','David Mwangi','Esther Achieng',
    'Faith Njeri','George Kiptoo','Halima Said','Ian Kamau','Jane Atieno',
    'Kevin Mutua','Lucy Wambui','Martin Odhiambo','Naomi Chebet','Oscar Maina',
    'Purity Moraa','Queen Akinyi','Robert Kariuki','Sarah Wafula','Thomas Musyoka',
    'Unity Naliaka','Victor Ouma','Winfred Jepkoech','Yvonne Muthoni','Zachary Kilonzo',
    'Alice Nekesa','Boniface Kirui','Cynthia Muli','Dennis Barasa','Eunice Nyambura'
  ];
  v_business_types text[] := array['Retail Shop','Salon','Food Kiosk','Farming','Transport','Tailoring'];
  v_principals numeric[] := array[5000,6000,7000,8000,10000,12000];
  i integer;
  j integer;
begin
  select s.id,s.email,b.display_name
    into v_admin_id,v_admin_email,v_display_name
  from public.patafix_platform_businesses b
  join public.loan_staff s on s.business_id=b.business_id
  where b.business_id=v_business_id
    and s.is_active=true
    and 'admin'=any(regexp_split_to_array(coalesce(s.role,''),'\s*,\s*'))
    and coalesce((b.settings->>'demo_mode')::boolean,false)=true
  order by (s.auth_user_id is not null) desc,s.created_at
  limit 1;

  if v_admin_id is null then
    raise exception 'The selected business is not an active demonstration tenant';
  end if;

  update public.patafix_platform_businesses
  set status='active',
      onboarding_fee=0,
      onboarding_payment_status='waived',
      subscription_start_date=null,
      monthly_fee_override=null,
      settings=coalesce(settings,'{}'::jsonb) || jsonb_build_object(
        'demo_mode',true,
        'enforcement_enabled',false,
        'vendor_app_unchanged',true
      ),
      notes='Platform demonstration tenant. No live financial integrations.',
      updated_at=now()
  where business_id=v_business_id;

  update public.loan_settings
  set company_name=v_display_name,
      company_email=v_admin_email,
      company_phone='0700 000 000',
      company_address='Demo Office, Kenya',
      mpesa_shortcode=null,
      mpesa_consumer_key=null,
      mpesa_consumer_secret=null,
      mpesa_passkey=null,
      daraja_credentials_saved=false,
      mpesa_auto_confirm=false,
      enable_rollover_penalties=false,
      updated_at=now()
  where business_id=v_business_id;

  delete from public.patafix_payment_routes where business_id=v_business_id;
  delete from public.patafix_daraja_credentials where business_id=v_business_id;
  delete from public.patafix_company_assets where business_id=v_business_id;
  delete from public.patafix_expenses where business_id=v_business_id;
  delete from public.journal_entries where business_id=v_business_id;
  delete from public.loan_audit_log where business_id=v_business_id;
  delete from public.mpesa_callback_queue where business_id=v_business_id;
  delete from public.unmatched_payments where business_id=v_business_id;
  delete from public.loan_billing_cycles where business_id=v_business_id;
  delete from public.loan_clients where business_id=v_business_id;
  delete from public.loan_products where business_id=v_business_id;
  delete from public.loan_staff where business_id=v_business_id and id<>v_admin_id;
  delete from public.patafix_branches where business_id=v_business_id;

  insert into public.patafix_branches
    (business_id,name,branch_code,manager_name,phone,location,status)
  values
    (v_business_id,'Head Office','HO','Demo Administrator','0700 000 000','Nairobi','active'),
    (v_business_id,'Central Branch','CB','Demo Branch Manager','0700 000 001','Nakuru','active'),
    (v_business_id,'Lakeside Branch','LB','Demo Branch Manager','0700 000 002','Kisumu','active')
  on conflict (business_id,name) do update
  set branch_code=excluded.branch_code,
      manager_name=excluded.manager_name,
      phone=excluded.phone,
      location=excluded.location,
      status='active',
      updated_at=now();

  insert into public.loan_staff
    (business_id,name,email,phone,role,is_active,branch_name)
  values
    (v_business_id,'Mary Demo Officer','demo.officer1@patafix.invalid','0700 100 001','loan_officer',true,'Head Office'),
    (v_business_id,'John Demo Officer','demo.officer2@patafix.invalid','0700 100 002','loan_officer',true,'Central Branch'),
    (v_business_id,'Lydia Demo Officer','demo.officer3@patafix.invalid','0700 100 003','loan_officer',true,'Lakeside Branch');

  insert into public.loan_products (
    business_id,name,description,min_amount,max_amount,interest_rate,interest_period,
    interest_type,min_term_weeks,max_term_weeks,processing_fee_type,
    processing_fee_value,processing_fee_pct,registration_fee,repayment_frequency,
    term_unit,requires_guarantor,is_active
  ) values
    (v_business_id,'INUA BIZ','KES 5,000-10,000 | configurable weekly loan',5000,10000,20,'monthly','flat',1,52,'flat',500,0,200,'weekly','weeks',true,true),
    (v_business_id,'KUZA','KES 11,000-15,000 | configurable weekly loan',11000,15000,20,'monthly','flat',1,52,'percent',5,5,300,'weekly','weeks',true,true),
    (v_business_id,'NAWIRI','KES 16,000-20,000 | configurable weekly loan',16000,20000,20,'monthly','flat',1,52,'percent',6,6,400,'weekly','weeks',true,true);

  select id into v_product_id
  from public.loan_products
  where business_id=v_business_id and is_active=true
  order by min_amount,id
  limit 1;

  if v_product_id is null then
    raise exception 'The demo business has no active loan product';
  end if;

  for i in 1..30 loop
    v_branch := (array['Head Office','Central Branch','Lakeside Branch'])[((i-1)%3)+1];
    select id into v_officer_id
    from public.loan_staff
    where business_id=v_business_id
      and email='demo.officer'||(((i-1)%3)+1)::text||'@patafix.invalid';

    insert into public.loan_clients (
      business_id,full_name,id_number,phone,email,gender,business_type,dob,address,
      occupation,monthly_income,next_of_kin_name,next_of_kin_phone,next_of_kin_relation,
      notes,status,loan_officer_id,created_by,branch_name,created_at
    ) values (
      v_business_id,v_names[i],'9000'||lpad(i::text,4,'0'),'0710'||lpad(i::text,6,'0'),
      'client'||i::text||'@demo.invalid',case when i%2=0 then 'Female' else 'Male' end,
      v_business_types[((i-1)%array_length(v_business_types,1))+1],
      date '1982-01-01'+(i*173),v_branch||' Market','Small business owner',
      18000+(i*700),'Demo Next of Kin '||i,'0720'||lpad(i::text,6,'0'),'Sibling',
      'PATAFIX_DEMO_SEED','active',v_officer_id,v_admin_id,v_branch,
      now()-(45-i)*interval '1 day'
    ) returning id into v_client_id;

    if i <= 27 then
      v_principal := v_principals[((i-1)%array_length(v_principals,1))+1];
      insert into public.loan_applications (
        business_id,application_no,client_id,product_id,loan_officer_id,applied_amount,
        applied_term_weeks,purpose,loan_type,guarantor_name,guarantor_phone,
        guarantor_relationship,status,application_date,approved_by,approved_at,branch_name
      ) values (
        v_business_id,'DEMO-APP-'||lpad(i::text,3,'0'),v_client_id,v_product_id,v_officer_id,
        v_principal,5,'Working capital','new_loan','Demo Guarantor '||i,
        '0730'||lpad(i::text,6,'0'),'Friend',
        case when i<=24 then 'disbursed' when i=25 then 'submitted' else 'approved' end,
        current_date-(32-i),case when i<=24 or i>=26 then v_admin_id else null end,
        case when i<=24 or i>=26 then now()-(31-i)*interval '1 day' else null end,v_branch
      ) returning id into v_application_id;
    end if;

    if i <= 24 then
      v_interest := round(v_principal*0.25,2);
      v_total := v_principal+v_interest;
      v_installment := round(v_total/5,2);

      if i <= 8 then
        v_disbursed := current_date-(75-i);
        v_paid_count := 5;
        v_status := 'completed';
      elsif i <= 18 then
        v_disbursed := current_date-21;
        v_paid_count := 2+(i%2);
        v_status := 'active';
      else
        v_disbursed := current_date-49;
        v_paid_count := 1+(i%2);
        v_status := 'active';
      end if;

      v_first_due := v_disbursed+7;
      v_maturity := v_first_due+28;
      v_total_paid := least(v_total,round(v_installment*v_paid_count,2));
      v_outstanding := greatest(0,v_total-v_total_paid);
      v_arrears := case when i between 19 and 24 then v_outstanding else 0 end;

      insert into public.loans (
        business_id,loan_no,application_id,client_id,loan_officer_id,principal_amount,
        disbursed_amount,interest_rate,interest_type,term_weeks,processing_fee,total_interest,
        total_payable,weekly_installment,disbursement_method,disbursement_reference,
        disbursement_date,first_repayment_date,maturity_date,status,outstanding_balance,
        total_paid,arrears_amount,overdue_days,loan_type,branch_name
      ) values (
        v_business_id,'DEMO-LN-'||lpad(i::text,3,'0'),v_application_id,v_client_id,v_officer_id,
        v_principal,v_principal,5,'flat',5,0,v_interest,v_total,v_installment,'mpesa',
        'DEMO-DISB-'||lpad(i::text,3,'0'),v_disbursed,v_first_due,v_maturity,v_status,
        v_outstanding,v_total_paid,v_arrears,
        case when v_arrears>0 then greatest(1,current_date-(v_first_due+(v_paid_count*7))) else 0 end,
        'new_loan',v_branch
      ) returning id into v_loan_id;

      for j in 1..5 loop
        v_due := v_first_due+((j-1)*7);
        insert into public.loan_schedules (
          business_id,loan_id,installment_no,due_date,principal_due,interest_due,total_due,
          principal_paid,interest_paid,total_paid,penalty_charged,status,paid_at,branch_name
        ) values (
          v_business_id,v_loan_id,j,v_due,round(v_principal/5,2),round(v_interest/5,2),v_installment,
          case when j<=v_paid_count then round(v_principal/5,2) else 0 end,
          case when j<=v_paid_count then round(v_interest/5,2) else 0 end,
          case when j<=v_paid_count then v_installment else 0 end,0,
          case when j<=v_paid_count then 'paid' when v_due<current_date then 'overdue' else 'pending' end,
          case when j<=v_paid_count then v_due+time '10:00' else null end,v_branch
        );

        if j <= v_paid_count then
          insert into public.loan_repayments (
            business_id,loan_id,receipt_no,amount,payment_method,payment_reference,payment_date,
            principal_portion,interest_portion,penalty_portion,mpesa_confirmed,collected_by,
            notes,branch_name
          ) values (
            v_business_id,v_loan_id,'DEMO-RCP-'||lpad(i::text,3,'0')||'-'||j,
            v_installment,case when j%2=0 then 'cash' else 'mpesa_c2b' end,
            'DEMO-PAY-'||lpad(i::text,3,'0')||'-'||j,v_due+time '10:00',
            round(v_principal/5,2),round(v_interest/5,2),0,j%2<>0,v_officer_id,
            'Demonstration repayment',v_branch
          );
        end if;
      end loop;

      insert into public.journal_entries
        (business_id,date,ref,description,debit,credit,amount,synced,branch_name)
      values
        (v_business_id,v_disbursed,'DEMO-DISB-'||lpad(i::text,3,'0'),
         'Demo loan disbursement','Loan Portfolio','Cash / M-Pesa',v_principal,true,v_branch);
    end if;
  end loop;

  insert into public.patafix_expenses (
    business_id,expense_no,expense_date,category,description,amount,payment_method,
    payment_reference,status,requested_by,approved_by,approved_at,branch_name
  )
  select v_business_id,'DEMO-EXP-'||lpad(x::text,3,'0'),current_date-(x*3),
    (array['Office rent','Fuel','Airtime','Printing & stationery expense','Marketing expense(cards/flyers)'])[((x-1)%5)+1],
    'Demonstration operating expense',500+(x*275),case when x%2=0 then 'mpesa' else 'cash' end,
    'DEMO-EXP-REF-'||x,'approved',v_admin_id,v_admin_id,now()-(x*3)*interval '1 day',
    (array['Head Office','Central Branch','Lakeside Branch'])[((x-1)%3)+1]
  from generate_series(1,10) x;

  insert into public.loan_audit_log
    (business_id,user_id,action,table_name,record_id,new_value)
  values (
    v_business_id,v_admin_id,'demo_data_seeded','platform_demo',v_business_id,
    jsonb_build_object('demo_seed',true,'clients',30,'loans',24,'email',v_admin_email)
  );

  if to_regprocedure('public.patafix_refresh_credit_scores_for_business(text)') is not null then
    execute 'select public.patafix_refresh_credit_scores_for_business($1)' using v_business_id;
  end if;

  return jsonb_build_object(
    'business_id',v_business_id,
    'status','Demo data refreshed',
    'clients',(select count(*) from public.loan_clients where business_id=v_business_id),
    'loans',(select count(*) from public.loans where business_id=v_business_id),
    'repayments',(select count(*) from public.loan_repayments where business_id=v_business_id),
    'expenses',(select count(*) from public.patafix_expenses where business_id=v_business_id)
  );
end;
$$;

revoke all on function public.patafix_reset_demo_business(text) from public;
grant execute on function public.patafix_reset_demo_business(text) to service_role;

select public.patafix_reset_demo_business((
  select business_id from public.loan_staff
  where lower(trim(email))='demoloan08@gmail.com'
  order by created_at limit 1
)) as reset_result;

commit;

select
  b.business_id,
  b.display_name,
  b.status,
  b.onboarding_payment_status,
  coalesce((b.settings->>'demo_mode')::boolean,false) as demo_mode,
  (select count(*) from public.loan_clients c where c.business_id=b.business_id) as clients,
  (select count(*) from public.loans l where l.business_id=b.business_id) as loans,
  (select count(*) from public.loan_repayments r where r.business_id=b.business_id) as repayments,
  (select count(*) from public.patafix_expenses e where e.business_id=b.business_id) as expenses,
  (select count(*) from public.loan_audit_log a where a.business_id=b.business_id) as audit_entries,
  (select count(*) from public.loan_audit_log a
   where a.business_id=b.business_id and coalesce(a.actor_name,'')<>'') as audit_entries_with_names
from public.patafix_platform_businesses b
where b.business_id=(
  select business_id from public.loan_staff
  where lower(trim(email))='demoloan08@gmail.com'
  order by created_at limit 1
);
