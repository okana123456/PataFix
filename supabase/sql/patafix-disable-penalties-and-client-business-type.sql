begin;

alter table public.loan_settings
  add column if not exists enable_rollover_penalties boolean not null default false;

alter table public.loan_clients
  add column if not exists business_type text;

insert into public.loan_settings (business_id, company_name, enable_rollover_penalties)
values ('BIZ-58D22296', 'PataFix', false)
on conflict (business_id) do update
set enable_rollover_penalties = false,
    updated_at = now();

create or replace function public.patafix_require_new_client_gender()
returns trigger
language plpgsql
as $$
begin
  if nullif(btrim(new.gender), '') is null then
    raise exception 'Gender is required when onboarding a new client';
  end if;
  return new;
end;
$$;

drop trigger if exists patafix_require_new_client_gender on public.loan_clients;
create trigger patafix_require_new_client_gender
before insert on public.loan_clients
for each row execute function public.patafix_require_new_client_gender();

do $$
declare
  v_business_id constant text := 'BIZ-58D22296';
  v_loan_id constant uuid := '78b984b0-4604-4e07-8038-a0e4132a3f81';
  v_schedule_id constant uuid := 'bdc79b37-a06c-4fe2-881f-2c33969b6b36';
  v_penalty_id constant uuid := '2892cd3e-f81f-4d5f-bac4-0a47a7d3cb61';
  v_penalty numeric(14,2);
  v_already_waived boolean;
  v_client_name text;
  v_loan_no text;
  v_paid_at timestamptz;
begin
  select p.penalty_amount, p.is_waived, c.full_name, l.loan_no
    into v_penalty, v_already_waived, v_client_name, v_loan_no
  from public.loan_penalties p
  join public.loans l on l.id = p.loan_id and l.business_id = p.business_id
  join public.loan_clients c on c.id = l.client_id and c.business_id = l.business_id
  where p.id = v_penalty_id
    and p.loan_id = v_loan_id
    and p.business_id = v_business_id
  for update of p, l;

  if not found then
    raise exception 'Grace penalty/loan record was not found. No financial data was changed.';
  end if;

  if upper(btrim(v_client_name)) <> 'GRACE WANGARI IRAE'
     or v_loan_no <> '886285'
     or v_penalty <> 62.50 then
    raise exception 'Grace record does not match the expected client, loan, and KES 62.50 penalty. No financial data was changed.';
  end if;

  if not v_already_waived then
    select max(payment_date)
      into v_paid_at
    from public.loan_repayments
    where loan_id = v_loan_id;

    update public.loan_penalties
    set is_waived = true,
        waived_reason = 'Waived after PataFix discontinued automatic maturity penalties',
        waived_by = null,
        waived_at = now()
    where id = v_penalty_id;

    update public.loan_schedules
    set penalty_charged = greatest(0, coalesce(penalty_charged, 0) - v_penalty),
        total_due = greatest(total_paid, total_due - v_penalty),
        status = 'paid',
        paid_at = coalesce(paid_at, v_paid_at, now()),
        updated_at = now()
    where id = v_schedule_id
      and loan_id = v_loan_id;

    if not found then
      raise exception 'Grace final schedule was not found. Transaction rolled back.';
    end if;

    update public.loans
    set total_payable = greatest(total_paid, total_payable - v_penalty),
        outstanding_balance = 0,
        arrears_amount = 0,
        overdue_days = 0,
        status = 'completed',
        updated_at = now()
    where id = v_loan_id
      and business_id = v_business_id;

    insert into public.loan_audit_log (
      business_id, user_id, action, table_name, record_id, old_value, new_value
    ) values (
      v_business_id,
      null,
      'maturity_penalty_waived',
      'loans',
      v_loan_id::text,
      jsonb_build_object('penalty_id', v_penalty_id, 'penalty_amount', v_penalty),
      jsonb_build_object(
        'client', v_client_name,
        'loan_no', v_loan_no,
        'penalty_waived', v_penalty,
        'outstanding_balance', 0,
        'status', 'completed',
        'reason', 'PataFix discontinued automatic maturity penalties'
      )
    );
  end if;
end $$;

commit;

select
  c.full_name as client,
  l.loan_no,
  l.status as loan_status,
  l.total_payable,
  l.total_paid,
  l.outstanding_balance,
  l.arrears_amount,
  l.overdue_days,
  s.total_due as final_installment_due,
  s.total_paid as final_installment_paid,
  s.penalty_charged,
  s.status as final_installment_status,
  p.penalty_amount,
  p.is_waived,
  p.waived_reason,
  settings.enable_rollover_penalties
from public.loans l
join public.loan_clients c on c.id = l.client_id
join public.loan_schedules s on s.id = 'bdc79b37-a06c-4fe2-881f-2c33969b6b36'
join public.loan_penalties p on p.id = '2892cd3e-f81f-4d5f-bac4-0a47a7d3cb61'
left join public.loan_settings settings on settings.business_id = l.business_id
where l.id = '78b984b0-4604-4e07-8038-a0e4132a3f81';
