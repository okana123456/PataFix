-- PataFix readable audit actors and durable account trails.
-- Run once in the PataFix Supabase SQL Editor.

begin;

alter table public.loan_audit_log
  add column if not exists actor_name text,
  add column if not exists actor_email text;

update public.loan_audit_log log
set actor_name = coalesce(log.actor_name, staff.name),
    actor_email = coalesce(log.actor_email, staff.email)
from public.loan_staff staff
where staff.id = log.user_id
  and staff.business_id = log.business_id
  and (log.actor_name is null or log.actor_email is null);

create or replace function public.patafix_snapshot_audit_actor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff public.loan_staff%rowtype;
begin
  if new.user_id is not null and (new.actor_name is null or new.actor_email is null) then
    select * into v_staff
    from public.loan_staff
    where id = new.user_id
      and business_id = new.business_id;

    if found then
      new.actor_name := coalesce(new.actor_name, v_staff.name);
      new.actor_email := coalesce(new.actor_email, v_staff.email);
    end if;
  end if;

  new.actor_name := coalesce(nullif(trim(new.actor_name), ''), 'System');
  return new;
end;
$$;

drop trigger if exists patafix_snapshot_audit_actor_trigger on public.loan_audit_log;
create trigger patafix_snapshot_audit_actor_trigger
before insert on public.loan_audit_log
for each row execute function public.patafix_snapshot_audit_actor();

create index if not exists loan_audit_log_record_timeline_idx
  on public.loan_audit_log (business_id, table_name, record_id, created_at desc);

commit;

select
  'PataFix audit account trail ready' as status,
  count(*) as audit_entries,
  count(*) filter (where actor_name is not null) as entries_with_actor_name
from public.loan_audit_log;
