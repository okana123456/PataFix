-- Repair seven Msambweni loans whose unpaid schedules were silently replaced
-- on 2026-11-13 with future dates and an extra 5% balance.
-- The script backs up affected rows, reconstructs the original contracts,
-- reapplies recorded repayments FIFO, and records an audit entry per loan.

begin;

-- Required when the cross-business schedule integrity safeguard is installed.
select set_config('app.patafix_schedule_change', 'controlled_repair', true);

create temporary table _patafix_msambweni_contracts (
  loan_no text primary key,
  expected_name text not null,
  expected_principal numeric(14,2) not null,
  first_due_date date not null,
  term_weeks integer not null,
  period_rate numeric(8,4) not null
) on commit drop;

insert into _patafix_msambweni_contracts values
  ('599114', 'Salome Ngatha Mukira',    8000, date '2026-09-11', 6, 5),
  ('123500', 'Pesa Salim Rachuwu',      6000, date '2026-10-01', 5, 5),
  ('439162', 'Mercy Mbodze Mwalenga',   8000, date '2026-10-16', 4, 5),
  ('329173', 'Martha Wambua',            8000, date '2026-10-09', 5, 5),
  ('296687', 'Susan Nduta Mwangi',       7000, date '2026-09-28', 6, 5),
  ('302003', 'Grace Mueni Mutinda',      8000, date '2026-09-22', 5, 5),
  ('271549', 'Veronica Mwethya Ndivo',   8000, date '2026-10-14', 4, 5);

create temporary table _patafix_msambweni_loans on commit drop as
select
  l.id as loan_id,
  l.business_id,
  l.loan_no,
  l.client_id,
  l.branch_name,
  c.full_name,
  cfg.first_due_date,
  cfg.term_weeks,
  cfg.period_rate,
  l.principal_amount,
  round(l.principal_amount * cfg.period_rate / 100 * cfg.term_weeks, 2) as original_interest,
  round(l.principal_amount * (1 + cfg.period_rate / 100 * cfg.term_weeks), 2) as original_total_payable,
  coalesce((
    select round(sum(r.amount), 2)
    from public.loan_repayments r
    where r.loan_id = l.id
      and r.business_id = l.business_id
  ), 0) as repayments_total
from _patafix_msambweni_contracts cfg
join public.loans l
  on l.loan_no = cfg.loan_no
 and l.business_id = 'BIZ-58D22296'
 and l.status = 'active'
join public.loan_clients c
  on c.id = l.client_id
 and c.business_id = l.business_id
where l.principal_amount = cfg.expected_principal
  and lower(c.full_name) like '%' || lower(split_part(cfg.expected_name, ' ', 1)) || '%';

do $$
declare
  v_count integer;
begin
  select count(*) into v_count from _patafix_msambweni_loans;
  if v_count <> 7 then
    raise exception 'Safety check stopped the repair: expected 7 verified active loans, found %.', v_count;
  end if;
end $$;

create table if not exists public.patafix_msambweni_loan_backup_20261115
(like public.loans including defaults);

create table if not exists public.patafix_msambweni_schedule_backup_20261115
(like public.loan_schedules including defaults);

create unique index if not exists patafix_msambweni_loan_backup_20261115_id_uidx
  on public.patafix_msambweni_loan_backup_20261115 (id);

create unique index if not exists patafix_msambweni_schedule_backup_20261115_id_uidx
  on public.patafix_msambweni_schedule_backup_20261115 (id);

alter table public.patafix_msambweni_loan_backup_20261115 enable row level security;
alter table public.patafix_msambweni_schedule_backup_20261115 enable row level security;
revoke all on public.patafix_msambweni_loan_backup_20261115 from anon, authenticated;
revoke all on public.patafix_msambweni_schedule_backup_20261115 from anon, authenticated;
grant all on public.patafix_msambweni_loan_backup_20261115 to service_role;
grant all on public.patafix_msambweni_schedule_backup_20261115 to service_role;

insert into public.patafix_msambweni_loan_backup_20261115
select l.*
from public.loans l
join _patafix_msambweni_loans target on target.loan_id = l.id
on conflict (id) do nothing;

insert into public.patafix_msambweni_schedule_backup_20261115
select s.*
from public.loan_schedules s
join _patafix_msambweni_loans target on target.loan_id = s.loan_id
on conflict (id) do nothing;

delete from public.loan_schedules s
using _patafix_msambweni_loans target
where s.loan_id = target.loan_id;

with schedule_parts as (
  select
    target.*,
    installment_no,
    target.first_due_date + ((installment_no - 1) * 7) as due_date,
    case
      when installment_no = target.term_weeks then
        target.principal_amount
          - round(target.principal_amount / target.term_weeks, 2) * (target.term_weeks - 1)
      else round(target.principal_amount / target.term_weeks, 2)
    end as principal_due,
    case
      when installment_no = target.term_weeks then
        target.original_interest
          - round(target.original_interest / target.term_weeks, 2) * (target.term_weeks - 1)
      else round(target.original_interest / target.term_weeks, 2)
    end as interest_due
  from _patafix_msambweni_loans target
  cross join lateral generate_series(1, target.term_weeks) installment_no
), schedule_totals as (
  select
    parts.*,
    round(parts.principal_due + parts.interest_due, 2) as total_due
  from schedule_parts parts
), allocated as (
  select
    totals.*,
    least(
      totals.total_due,
      greatest(
        totals.repayments_total
          - coalesce(sum(totals.total_due) over (
              partition by totals.loan_id
              order by totals.installment_no
              rows between unbounded preceding and 1 preceding
            ), 0),
        0
      )
    ) as allocated_paid
  from schedule_totals totals
), final_rows as (
  select
    allocated.*,
    round(
      case when allocated.total_due > 0
        then allocated.allocated_paid * allocated.principal_due / allocated.total_due
        else 0
      end,
      2
    ) as principal_paid_calc
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
  null,
  row.branch_name,
  now(),
  now()
from final_rows row;

with corrected as (
  select
    target.loan_id,
    target.original_interest,
    target.original_total_payable,
    target.repayments_total,
    target.term_weeks,
    target.first_due_date,
    target.first_due_date + ((target.term_weeks - 1) * 7) as maturity_date,
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
  from _patafix_msambweni_loans target
  join public.loan_schedules schedule on schedule.loan_id = target.loan_id
  group by
    target.loan_id,
    target.original_interest,
    target.original_total_payable,
    target.repayments_total,
    target.term_weeks,
    target.first_due_date
)
update public.loans loan
set
  term_weeks = corrected.term_weeks,
  interest_rate = 5,
  total_interest = corrected.original_interest,
  total_payable = corrected.original_total_payable,
  weekly_installment = corrected.installment_amount,
  first_repayment_date = corrected.first_due_date,
  maturity_date = corrected.maturity_date,
  total_paid = corrected.repayments_total,
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
    'outstanding_balance', backup.outstanding_balance,
    'arrears_amount', backup.arrears_amount,
    'overdue_days', backup.overdue_days
  ),
  jsonb_build_object(
    'reason', 'Reversed unaudited 2026-11-13 future schedule replacement and extra 5 percent balance',
    'first_repayment_date', loan.first_repayment_date,
    'maturity_date', loan.maturity_date,
    'total_interest', loan.total_interest,
    'total_payable', loan.total_payable,
    'total_paid', loan.total_paid,
    'outstanding_balance', loan.outstanding_balance,
    'arrears_amount', loan.arrears_amount,
    'overdue_days', loan.overdue_days
  )
from public.loans loan
join _patafix_msambweni_loans target on target.loan_id = loan.id
join public.patafix_msambweni_loan_backup_20261115 backup on backup.id = loan.id
where not exists (
  select 1
  from public.loan_audit_log audit
  where audit.business_id = loan.business_id
    and audit.record_id = loan.id::text
    and audit.action = 'incorrect_schedule_shift_reversed'
);

commit;

select
  client.full_name as client,
  loan.loan_no,
  loan.first_repayment_date,
  loan.maturity_date,
  loan.term_weeks,
  loan.total_payable,
  loan.total_paid as loan_total_paid,
  loan.outstanding_balance,
  loan.arrears_amount,
  loan.overdue_days,
  schedule.installment_no,
  schedule.due_date,
  schedule.total_due,
  schedule.total_paid as installment_paid,
  greatest(schedule.total_due - schedule.total_paid, 0) as remaining,
  schedule.status
from public.loans loan
join public.loan_clients client on client.id = loan.client_id
join public.loan_schedules schedule on schedule.loan_id = loan.id
where loan.business_id = 'BIZ-58D22296'
  and loan.loan_no in ('599114','123500','439162','329173','296687','302003','271549')
order by client.full_name, schedule.installment_no;
