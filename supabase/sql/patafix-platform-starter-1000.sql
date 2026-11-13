-- PataFix platform Starter package pricing.
-- Safe to run more than once. This does not enable subscription locking.

begin;

update public.patafix_platform_plans
set name = 'Starter',
    description = 'Single-branch package for up to 1,000 clients',
    onboarding_fee = 7500,
    monthly_fee = 3000,
    max_clients = 1000,
    max_branches = 1,
    updated_at = now()
where code = 'starter';

commit;

select
  code,
  name,
  onboarding_fee,
  monthly_fee,
  max_clients,
  max_branches,
  'Subscription starts on the first day of the month after onboarding confirmation' as billing_rule
from public.patafix_platform_plans
where code = 'starter';
