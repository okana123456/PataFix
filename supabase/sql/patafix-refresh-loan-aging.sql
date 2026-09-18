-- Keeps installment statuses and loan-level arrears aligned with Kenya dates.
-- Safe to run more than once.

create or replace function public.patafix_refresh_loan_aging(
  p_business_id text,
  p_loan_id uuid default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Africa/Nairobi')::date;
  v_schedule_updates integer := 0;
  v_loan_updates integer := 0;
begin
  update public.loan_schedules s
  set status = case
        when coalesce(s.total_paid,0) >= coalesce(s.total_due,0) - 0.005 then 'paid'
        when s.due_date < v_today then 'overdue'
        when coalesce(s.total_paid,0) > 0 then 'partial'
        else 'pending'
      end,
      updated_at = now()
  where s.business_id = p_business_id
    and (p_loan_id is null or s.loan_id = p_loan_id)
    and lower(coalesce(s.status,'')) not in ('restructured','cancelled','waived')
    and s.status is distinct from case
          when coalesce(s.total_paid,0) >= coalesce(s.total_due,0) - 0.005 then 'paid'
          when s.due_date < v_today then 'overdue'
          when coalesce(s.total_paid,0) > 0 then 'partial'
          else 'pending'
        end;
  get diagnostics v_schedule_updates = row_count;

  with aging as (
    select
      l.id as loan_id,
      coalesce(sum(
        case
          when s.due_date < v_today
            and lower(coalesce(s.status,'')) not in ('restructured','cancelled','waived')
          then greatest(coalesce(s.total_due,0)-coalesce(s.total_paid,0),0)
          else 0
        end
      ),0)::numeric(14,2) as arrears_amount,
      min(s.due_date) filter (
        where s.due_date < v_today
          and greatest(coalesce(s.total_due,0)-coalesce(s.total_paid,0),0) > 0.005
          and lower(coalesce(s.status,'')) not in ('restructured','cancelled','waived')
      ) as oldest_unpaid_date
    from public.loans l
    left join public.loan_schedules s
      on s.loan_id = l.id and s.business_id = l.business_id
    where l.business_id = p_business_id
      and l.status = 'active'
      and (p_loan_id is null or l.id = p_loan_id)
    group by l.id
  )
  update public.loans l
  set arrears_amount = a.arrears_amount,
      overdue_days = case
        when a.oldest_unpaid_date is null then 0
        else v_today - a.oldest_unpaid_date
      end,
      updated_at = now()
  from aging a
  where l.id = a.loan_id
    and (
      l.arrears_amount is distinct from a.arrears_amount
      or l.overdue_days is distinct from case
        when a.oldest_unpaid_date is null then 0
        else v_today - a.oldest_unpaid_date
      end
    );
  get diagnostics v_loan_updates = row_count;

  return jsonb_build_object(
    'ok',true,
    'as_of_date',v_today,
    'schedule_updates',v_schedule_updates,
    'loan_updates',v_loan_updates
  );
end;
$$;

grant execute on function public.patafix_refresh_loan_aging(text,uuid) to authenticated;

select public.patafix_refresh_loan_aging('BIZ-58D22296',null::uuid) as result;

-- Verification for the reported loan. On 18/09/2026, installment #4 should
-- be overdue and installment #5 should remain pending until after 21/09/2026.
select
  c.full_name as client,
  l.loan_no,
  l.arrears_amount,
  l.overdue_days,
  s.installment_no,
  s.due_date,
  s.total_due,
  s.total_paid,
  greatest(s.total_due-s.total_paid,0) as remaining,
  s.status
from public.loans l
join public.loan_clients c on c.id=l.client_id
join public.loan_schedules s on s.loan_id=l.id
where l.business_id='BIZ-58D22296'
  and l.loan_no='070223'
order by s.due_date,s.installment_no;
