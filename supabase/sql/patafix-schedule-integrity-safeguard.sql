-- PataFix multi-business repayment schedule integrity safeguard.
-- Protects every tenant without changing ordinary repayment operations.

begin;

create table if not exists public.patafix_schedule_integrity_events (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  loan_id uuid not null,
  schedule_id uuid,
  operation text not null,
  change_context text,
  actor_auth_id uuid,
  old_value jsonb,
  new_value jsonb,
  created_at timestamptz not null default now()
);

alter table public.patafix_schedule_integrity_events enable row level security;
revoke all on public.patafix_schedule_integrity_events from anon, authenticated;
grant all on public.patafix_schedule_integrity_events to service_role;

create index if not exists patafix_schedule_integrity_events_business_time_idx
  on public.patafix_schedule_integrity_events (business_id, created_at desc);

create index if not exists patafix_schedule_integrity_events_loan_time_idx
  on public.patafix_schedule_integrity_events (loan_id, created_at desc);

create or replace function public.patafix_protect_schedule_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_context text := coalesce(current_setting('app.patafix_schedule_change', true), '');
  v_has_repayments boolean := false;
  v_loan record;
  v_structural_update boolean := false;
begin
  if tg_op = 'DELETE' then
    select id, business_id, loan_no, status, term_weeks, maturity_date
      into v_loan
    from public.loans
    where id = old.loan_id;

    if found and v_context not in (
      'approved_restructure',
      'approved_recall',
      'controlled_repair',
      'approved_loan_delete',
      'approved_import_cleanup',
      'approved_demo_reset'
    ) then
      insert into public.patafix_schedule_integrity_events (
        business_id, loan_id, schedule_id, operation, change_context,
        actor_auth_id, old_value
      ) values (
        old.business_id, old.loan_id, old.id, 'delete', nullif(v_context,''),
        auth.uid(), to_jsonb(old)
      );
    end if;

    return old;
  end if;

  select id, business_id, loan_no, status, term_weeks, maturity_date
    into v_loan
  from public.loans
  where id = new.loan_id;

  if not found then
    raise exception 'Schedule integrity check failed: parent loan was not found.';
  end if;

  if new.business_id is distinct from v_loan.business_id then
    raise exception 'Schedule integrity check failed: schedule and loan belong to different businesses.';
  end if;

  if tg_op = 'INSERT' then
    select exists (
      select 1
      from public.loan_repayments repayment
      where repayment.loan_id = new.loan_id
        and repayment.business_id = new.business_id
    ) into v_has_repayments;

    if v_has_repayments and v_context not in (
      'approved_restructure',
      'controlled_repair',
      'approved_demo_reset'
    ) then
      raise exception using
        message = format(
          'Protected schedule: loan %s already has repayments. Use the approved Restructure action or an authorised controlled repair.',
          coalesce(v_loan.loan_no, new.loan_id::text)
        ),
        hint = 'No schedule was changed and existing business operations remain intact.';
    end if;

    if coalesce(new.installment_no,0) < 1 then
      raise exception 'Schedule integrity check failed: installment number must be positive.';
    end if;

    return new;
  end if;

  v_structural_update :=
       old.due_date is distinct from new.due_date
    or old.installment_no is distinct from new.installment_no
    or old.principal_due is distinct from new.principal_due
    or old.interest_due is distinct from new.interest_due
    or old.total_due is distinct from new.total_due;

  if v_structural_update and v_context not in (
    'approved_restructure',
    'controlled_repair'
  ) then
    insert into public.patafix_schedule_integrity_events (
      business_id, loan_id, schedule_id, operation, change_context,
      actor_auth_id, old_value, new_value
    ) values (
      new.business_id, new.loan_id, new.id, 'structural_update', nullif(v_context,''),
      auth.uid(), to_jsonb(old), to_jsonb(new)
    );
  end if;

  return new;
end;
$$;

drop trigger if exists patafix_schedule_integrity_guard on public.loan_schedules;
create trigger patafix_schedule_integrity_guard
before insert or update or delete on public.loan_schedules
for each row execute function public.patafix_protect_schedule_integrity();

commit;

select
  'PataFix schedule integrity safeguard ready' as status,
  count(*) as existing_integrity_events,
  count(distinct business_id) as businesses_with_logged_events
from public.patafix_schedule_integrity_events;
