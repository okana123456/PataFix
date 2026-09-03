-- PataFix: branch/staff portfolio alignment helper.
-- Run section 1 first to see staff still assigned to Head Office.
-- Run section 2 to see active client/loan records that do not match the officer branch.
-- Run section 3 only if you want to align active portfolios to each officer's current branch.

-- 1) Active staff still assigned to Head Office or blank branch.
select
  s.id,
  s.name,
  s.email,
  s.phone,
  s.role,
  coalesce(nullif(trim(s.branch_name), ''), 'Head Office') as staff_branch,
  count(distinct l.client_id) filter (
    where l.status = 'active' and coalesce(l.outstanding_balance, 0) > 0
  ) as active_clients
from public.loan_staff s
left join public.loans l
  on l.business_id = s.business_id
 and l.loan_officer_id = s.id
where s.business_id = 'BIZ-58D22296'
  and coalesce(s.is_active, true) = true
  and coalesce(nullif(trim(s.branch_name), ''), 'Head Office') = 'Head Office'
group by s.id, s.name, s.email, s.phone, s.role, s.branch_name
order by s.name;

-- 2) Active portfolios where client/loan branch does not match assigned officer branch.
select
  s.name as officer,
  coalesce(nullif(trim(s.branch_name), ''), 'Head Office') as officer_branch,
  c.full_name as client,
  coalesce(nullif(trim(c.branch_name), ''), 'Head Office') as client_branch,
  l.loan_no,
  coalesce(nullif(trim(l.branch_name), ''), 'Head Office') as loan_branch,
  l.status,
  l.outstanding_balance
from public.loans l
join public.loan_clients c on c.id = l.client_id
left join public.loan_staff s on s.id = l.loan_officer_id
where l.business_id = 'BIZ-58D22296'
  and l.status = 'active'
  and coalesce(l.outstanding_balance, 0) > 0
  and s.id is not null
  and (
    coalesce(nullif(trim(c.branch_name), ''), 'Head Office') <> coalesce(nullif(trim(s.branch_name), ''), 'Head Office')
    or coalesce(nullif(trim(l.branch_name), ''), 'Head Office') <> coalesce(nullif(trim(s.branch_name), ''), 'Head Office')
  )
order by officer_branch, officer, client;

-- 3) Optional repair: align active client/loan/application/schedule/repayment records
-- to the assigned officer's branch, but only for officers already moved out of Head Office.
with officer_branch as (
  select
    id as officer_id,
    business_id,
    coalesce(nullif(trim(branch_name), ''), 'Head Office') as branch_name
  from public.loan_staff
  where business_id = 'BIZ-58D22296'
    and coalesce(is_active, true) = true
    and coalesce(nullif(trim(branch_name), ''), 'Head Office') <> 'Head Office'
),
active_loans as (
  select
    l.id as loan_id,
    l.client_id,
    l.loan_officer_id,
    ob.branch_name
  from public.loans l
  join officer_branch ob
    on ob.officer_id = l.loan_officer_id
   and ob.business_id = l.business_id
  where l.business_id = 'BIZ-58D22296'
    and l.status = 'active'
    and coalesce(l.outstanding_balance, 0) > 0
),
updated_clients as (
  update public.loan_clients c
  set branch_name = a.branch_name,
      updated_at = now()
  from active_loans a
  where c.id = a.client_id
    and c.business_id = 'BIZ-58D22296'
    and coalesce(nullif(trim(c.branch_name), ''), 'Head Office') <> a.branch_name
  returning c.id
),
updated_loans as (
  update public.loans l
  set branch_name = a.branch_name,
      updated_at = now()
  from active_loans a
  where l.id = a.loan_id
    and l.business_id = 'BIZ-58D22296'
    and coalesce(nullif(trim(l.branch_name), ''), 'Head Office') <> a.branch_name
  returning l.id
),
updated_apps as (
  update public.loan_applications app
  set branch_name = ob.branch_name,
      updated_at = now()
  from officer_branch ob
  where app.business_id = 'BIZ-58D22296'
    and app.loan_officer_id = ob.officer_id
    and coalesce(nullif(trim(app.branch_name), ''), 'Head Office') <> ob.branch_name
  returning app.id
),
updated_schedules as (
  update public.loan_schedules sc
  set branch_name = a.branch_name,
      updated_at = now()
  from active_loans a
  where sc.business_id = 'BIZ-58D22296'
    and sc.loan_id = a.loan_id
    and coalesce(nullif(trim(sc.branch_name), ''), 'Head Office') <> a.branch_name
  returning sc.id
),
updated_repayments as (
  update public.loan_repayments r
  set branch_name = a.branch_name,
      updated_at = now()
  from active_loans a
  where r.business_id = 'BIZ-58D22296'
    and r.loan_id = a.loan_id
    and coalesce(nullif(trim(r.branch_name), ''), 'Head Office') <> a.branch_name
  returning r.id
)
select
  'Branch portfolio alignment complete' as status,
  (select count(*) from updated_clients) as clients_updated,
  (select count(*) from updated_loans) as loans_updated,
  (select count(*) from updated_apps) as applications_updated,
  (select count(*) from updated_schedules) as schedules_updated,
  (select count(*) from updated_repayments) as repayments_updated;
