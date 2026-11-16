-- Repair every remaining live PataFix loan affected by the unaudited
-- 13 November 2026 schedule shift. This targets the exact corruption
-- signature only and preserves/reapplies every recorded repayment.

begin;

select set_config('app.patafix_schedule_change', 'controlled_repair', true);

create temporary table _patafix_shifted_rows on commit drop as
select s.*
from public.loan_schedules s
where s.business_id = 'BIZ-58D22296'
  and timezone('Africa/Nairobi', s.created_at)::date = date '2026-11-13'
  and coalesce(s.installment_no, 0) >= 1000000
  and coalesce(s.interest_due, 0) = 0;

create temporary table _patafix_shifted_repair on commit drop as
with replacement_totals as (
  select
    loan_id,
    count(*) as replacement_rows,
    round(sum(total_due), 2) as replacement_total_due
  from _patafix_shifted_rows
  group by loan_id
), repayment_totals as (
  select
    repayment.loan_id,
    round(sum(repayment.amount), 2) as repayments_total
  from public.loan_repayments repayment
  join replacement_totals replacement on replacement.loan_id = repayment.loan_id
  where repayment.business_id = 'BIZ-58D22296'
  group by repayment.loan_id
)
select
  loan.id as loan_id,
  loan.business_id,
  loan.loan_no,
  loan.client_id,
  loan.branch_name,
  client.full_name,
  loan.first_repayment_date,
  loan.term_weeks,
  loan.principal_amount,
  replacement.replacement_rows,
  replacement.replacement_total_due,
  round(
    replacement.replacement_total_due
      - (replacement.replacement_total_due / 1.05),
    2
  ) as wrongly_added_amount,
  round(
    loan.total_payable
      - round(replacement.replacement_total_due - (replacement.replacement_total_due / 1.05), 2),
    2
  ) as original_total_payable,
  coalesce(repayment.repayments_total, 0) as repayments_total
from replacement_totals replacement
join public.loans loan
  on loan.id = replacement.loan_id
 and loan.business_id = 'BIZ-58D22296'
 and loan.status = 'active'
join public.loan_clients client
  on client.id = loan.client_id
 and client.business_id = loan.business_id
left join repayment_totals repayment on repayment.loan_id = loan.id;

do $$
declare
  v_total integer;
  v_malindi integer;
  v_msambweni integer;
  v_bad_rows integer;
begin
  select
    count(*),
    count(*) filter (where branch_name = 'Malindi Branch'),
    count(*) filter (where branch_name = 'Msambweni Branch'),
    count(*) filter (
      where replacement_rows <> 3
         or term_weeks < 1
         or original_total_payable < principal_amount
         or wrongly_added_amount <= 0
    )
  into v_total, v_malindi, v_msambweni, v_bad_rows
  from _patafix_shifted_repair;

  if v_total <> 13 or v_malindi <> 10 or v_msambweni <> 3 then
    raise exception
      'Safety check stopped repair: expected 13 loans (10 Malindi, 3 Msambweni), found % (% Malindi, % Msambweni).',
      v_total, v_malindi, v_msambweni;
  end if;

  if v_bad_rows <> 0 then
    raise exception 'Safety check stopped repair: % target loans failed contract validation.', v_bad_rows;
  end if;
end $$;

create table if not exists public.patafix_shifted_loan_backup_20261116
(like public.loans including defaults);

create table if not exists public.patafix_shifted_schedule_backup_20261116
(like public.loan_schedules including defaults);

create unique index if not exists patafix_shifted_loan_backup_20261116_id_uidx
  on public.patafix_shifted_loan_backup_20261116 (id);

create unique index if not exists patafix_shifted_schedule_backup_20261116_id_uidx
  on public.patafix_shifted_schedule_backup_20261116 (id);

alter table public.patafix_shifted_loan_backup_20261116 enable row level security;
alter table public.patafix_shifted_schedule_backup_20261116 enable row level security;
revoke all on public.patafix_shifted_loan_backup_20261116 from anon, authenticated;
revoke all on public.patafix_shifted_schedule_backup_20261116 from anon, authenticated;
grant all on public.patafix_shifted_loan_backup_20261116 to service_role;
grant all on public.patafix_shifted_schedule_backup_20261116 to service_role;

insert into public.patafix_shifted_loan_backup_20261116
select loan.*
from public.loans loan
join _patafix_shifted_repair target on target.loan_id = loan.id
on conflict (id) do nothing;

insert into public.patafix_shifted_schedule_backup_20261116
select schedule.*
from public.loan_schedules schedule
join _patafix_shifted_repair target on target.loan_id = schedule.loan_id
on conflict (id) do nothing;

delete from public.loan_schedules schedule
using _patafix_shifted_repair target
where schedule.loan_id = target.loan_id;

with schedule_parts as (
  select
    target.*,
    installment_no,
    target.first_repayment_date + ((installment_no - 1) * 7) as due_date,
    case
      when installment_no = target.term_weeks then
        target.principal_amount
          - round(target.principal_amount / target.term_weeks, 2) * (target.term_weeks - 1)
      else round(target.principal_amount / target.term_weeks, 2)
    end as principal_due,
    case
      when installment_no = target.term_weeks then
        (target.original_total_payable - target.principal_amount)
          - round(
              (target.original_total_payable - target.principal_amount) / target.term_weeks,
              2
            ) * (target.term_weeks - 1)
      else round(
        (target.original_total_payable - target.principal_amount) / target.term_weeks,
        2
      )
    end as interest_due,
    least(target.repayments_total, target.original_total_payable) as applied_repayments
  from _patafix_shifted_repair target
  cross join lateral generate_series(1, target.term_weeks) installment_no
), schedule_totals as (
  select
    parts.*,
    round(parts.principal_due + parts.interest_due, 2) as total_due
  from schedule_parts parts
), schedule_cumulative as (
  select
    totals.*,
    coalesce(sum(totals.total_due) over (
      partition by totals.loan_id
      order by totals.installment_no
      rows between unbounded preceding and 1 preceding
    ), 0) as prior_due,
    sum(totals.total_due) over (
      partition by totals.loan_id
      order by totals.installment_no
      rows between unbounded preceding and current row
    ) as cumulative_due
  from schedule_totals totals
), allocated as (
  select
    cumulative.*,
    least(
      cumulative.total_due,
      greatest(cumulative.applied_repayments - cumulative.prior_due, 0)
    ) as allocated_paid
  from schedule_cumulative cumulative
), repayment_timeline as (
  select
    repayment.loan_id,
    repayment.payment_date,
    sum(repayment.amount) over (
      partition by repayment.loan_id
      order by repayment.payment_date, repayment.created_at, repayment.id
      rows between unbounded preceding and current row
    ) as cumulative_paid
  from public.loan_repayments repayment
  join _patafix_shifted_repair target on target.loan_id = repayment.loan_id
  where repayment.business_id = 'BIZ-58D22296'
), final_rows as (
  select
    allocated.*,
    round(
      case when allocated.total_due > 0
        then allocated.allocated_paid * allocated.principal_due / allocated.total_due
        else 0
      end,
      2
    ) as principal_paid_calc,
    case when allocated.allocated_paid >= allocated.total_due - 0.01 then (
      select min(timeline.payment_date)
      from repayment_timeline timeline
      where timeline.loan_id = allocated.loan_id
        and timeline.cumulative_paid >= allocated.cumulative_due - 0.01
    ) else null end as paid_at_calc
  from allocated
)
insert into public.loan_schedules (
  business_id,
  loan_id,
  installment_no,
  due_date,
  principal_due,
  interest_due,
  total_due,
  principal_paid,
  interest_paid,
  total_paid,
  penalty_charged,
  status,
  paid_at,
  branch_name,
  created_at,
  updated_at
)
select
  row.business_id,
  row.loan_id,
  row.installment_no,
  row.due_date,
  row.principal_due,
  row.interest_due,
  row.total_due,
  least(row.principal_due, row.principal_paid_calc),
  least(
    row.interest_due,
    greatest(row.allocated_paid - least(row.principal_due, row.principal_paid_calc), 0)
  ),
  row.allocated_paid,
  0,
  case
    when row.allocated_paid >= row.total_due - 0.01 then 'paid'
    when row.allocated_paid > 0 then 'partial'
    when row.due_date < current_date then 'overdue'
    else 'pending'
  end,
  row.paid_at_calc,
  row.branch_name,
  now(),
  now()
from final_rows row;

with corrected as (
  select
    target.loan_id,
    target.first_repayment_date,
    target.term_weeks,
    target.principal_amount,
    target.original_total_payable,
    least(target.repayments_total, target.original_total_payable) as applied_repayments,
    greatest(target.repayments_total - target.original_total_payable, 0) as excess_repayment,
    target.first_repayment_date + ((target.term_weeks - 1) * 7) as maturity_date,
    round(target.original_total_payable / target.term_weeks, 2) as installment_amount,
    greatest(target.original_total_payable - target.repayments_total, 0) as outstanding_balance,
    coalesce(sum(
      case when schedule.due_date < current_date
        then greatest(schedule.total_due - schedule.total_paid, 0)
        else 0
      end
    ), 0) as arrears_amount,
    min(schedule.due_date) filter (
      where schedule.due_date < current_date
        and schedule.total_due - schedule.total_paid > 0.01
    ) as oldest_unpaid_due
  from _patafix_shifted_repair target
  join public.loan_schedules schedule on schedule.loan_id = target.loan_id
  group by
    target.loan_id,
    target.first_repayment_date,
    target.term_weeks,
    target.principal_amount,
    target.original_total_payable,
    target.repayments_total
)
update public.loans loan
set
  term_weeks = corrected.term_weeks,
  first_repayment_date = corrected.first_repayment_date,
  maturity_date = corrected.maturity_date,
  total_interest = corrected.original_total_payable - corrected.principal_amount,
  total_payable = corrected.original_total_payable,
  weekly_installment = corrected.installment_amount,
  total_paid = corrected.applied_repayments,
  outstanding_balance = corrected.outstanding_balance,
  arrears_amount = corrected.arrears_amount,
  overdue_days = case
    when corrected.oldest_unpaid_due is null then 0
    else current_date - corrected.oldest_unpaid_due
  end,
  status = case when corrected.outstanding_balance <= 0.01 then 'completed' else 'active' end,
  updated_at = now()
from corrected
where loan.id = corrected.loan_id;

-- Preserve any payment above the restored contract as client credit.
insert into public.client_charge_transactions (
  business_id,
  client_id,
  loan_id,
  transaction_type,
  charge_type,
  amount,
  transaction_date,
  reference,
  payment_method,
  description,
  source_key,
  created_by
)
select
  target.business_id,
  target.client_id,
  target.loan_id,
  'adjustment_credit',
  'excess',
  round(target.repayments_total - target.original_total_payable, 2),
  current_date,
  'SCHFIX-' || target.loan_no,
  'system_adjustment',
  'Excess repayment restored after reversing the unaudited 13 November schedule shift',
  'schedule-repair-20261116:' || target.loan_id::text || ':excess',
  null
from _patafix_shifted_repair target
where target.repayments_total > target.original_total_payable + 0.01
  and not exists (
    select 1
    from public.client_charge_transactions existing
    where existing.business_id = target.business_id
      and existing.source_key = 'schedule-repair-20261116:' || target.loan_id::text || ':excess'
  );

insert into public.loan_audit_log (
  business_id,
  user_id,
  actor_name,
  action,
  table_name,
  record_id,
  old_value,
  new_value
)
select
  loan.business_id,
  null,
  'PataFix controlled schedule repair',
  'incorrect_schedule_shift_reversed',
  'loans',
  loan.id::text,
  jsonb_build_object(
    'maturity_date', backup.maturity_date,
    'total_interest', backup.total_interest,
    'total_payable', backup.total_payable,
    'total_paid', backup.total_paid,
    'outstanding_balance', backup.outstanding_balance,
    'arrears_amount', backup.arrears_amount,
    'overdue_days', backup.overdue_days
  ),
  jsonb_build_object(
    'reason', 'Reversed unaudited 13 November future schedule replacement and added 5 percent',
    'first_repayment_date', loan.first_repayment_date,
    'maturity_date', loan.maturity_date,
    'total_interest', loan.total_interest,
    'total_payable', loan.total_payable,
    'total_paid', loan.total_paid,
    'outstanding_balance', loan.outstanding_balance,
    'arrears_amount', loan.arrears_amount,
    'overdue_days', loan.overdue_days,
    'excess_to_charges', greatest(target.repayments_total - target.original_total_payable, 0)
  )
from public.loans loan
join _patafix_shifted_repair target on target.loan_id = loan.id
join public.patafix_shifted_loan_backup_20261116 backup on backup.id = loan.id
where not exists (
  select 1
  from public.loan_audit_log audit
  where audit.business_id = loan.business_id
    and audit.record_id = loan.id::text
    and audit.action = 'incorrect_schedule_shift_reversed'
);

commit;

select
  coalesce(loan.branch_name, client.branch_name, 'Unassigned') as branch,
  coalesce(staff.name, 'Unassigned') as loan_officer,
  client.full_name as client,
  loan.loan_no,
  loan.status,
  loan.first_repayment_date,
  loan.maturity_date,
  loan.term_weeks,
  loan.total_payable,
  loan.total_paid,
  loan.outstanding_balance,
  loan.arrears_amount,
  loan.overdue_days,
  count(schedule.id) as schedule_rows,
  min(schedule.due_date) as first_due,
  max(schedule.due_date) as last_due,
  round(sum(schedule.total_due), 2) as schedule_total_due,
  round(sum(schedule.total_paid), 2) as schedule_total_paid,
  round(sum(greatest(schedule.total_due - schedule.total_paid, 0)), 2) as schedule_remaining,
  coalesce((
    select round(sum(charge.amount), 2)
    from public.client_charge_transactions charge
    where charge.business_id = loan.business_id
      and charge.client_id = loan.client_id
      and charge.source_key = 'schedule-repair-20261116:' || loan.id::text || ':excess'
  ), 0) as excess_restored_to_charges
from public.loans loan
join public.loan_clients client on client.id = loan.client_id
left join public.loan_staff staff on staff.id = loan.loan_officer_id
join public.loan_schedules schedule on schedule.loan_id = loan.id
where loan.business_id = 'BIZ-58D22296'
  and loan.id in (
    select backup.id
    from public.patafix_shifted_loan_backup_20261116 backup
  )
group by
  loan.id,
  loan.branch_name,
  client.branch_name,
  client.full_name,
  staff.name
order by branch, loan_officer, client.full_name;
