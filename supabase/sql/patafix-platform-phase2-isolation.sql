-- PataFix platform Phase 2: tenant isolation and vendor payment routing.
-- Additive and backward compatible. Existing PataFix callbacks keep using the
-- same shortcode and callback URLs; the route registry only makes ownership
-- explicit and prevents one shortcode from being assigned to two businesses.

begin;

create table if not exists public.patafix_payment_routes (
  id uuid primary key default gen_random_uuid(),
  business_id text not null,
  provider text not null default 'daraja' check (provider in ('daraja')),
  shortcode text not null,
  environment text not null default 'production' check (environment in ('sandbox','production')),
  status text not null default 'active' check (status in ('pending','active','disabled')),
  validation_url text,
  confirmation_url text,
  registered_at timestamptz,
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, shortcode),
  unique (business_id, provider)
);

create index if not exists patafix_payment_routes_business_idx
  on public.patafix_payment_routes (business_id, status);

drop trigger if exists set_updated_at on public.patafix_payment_routes;
create trigger set_updated_at before update on public.patafix_payment_routes
for each row execute function public.set_updated_at();

do $$
declare
  v_duplicates text;
begin
  select string_agg(shortcode || ' (' || businesses || ')', ', ')
    into v_duplicates
  from (
    select trim(mpesa_shortcode) as shortcode,
           string_agg(business_id, ', ' order by business_id) as businesses
    from public.loan_settings
    where nullif(trim(mpesa_shortcode), '') is not null
    group by trim(mpesa_shortcode)
    having count(distinct business_id) > 1
  ) d;

  if v_duplicates is not null then
    raise exception 'Duplicate M-Pesa shortcode ownership must be resolved before Phase 2: %', v_duplicates;
  end if;
end $$;

insert into public.patafix_payment_routes (
  business_id, provider, shortcode, environment, status,
  validation_url, confirmation_url, registered_at
)
select
  s.business_id,
  'daraja',
  trim(s.mpesa_shortcode),
  case when lower(coalesce(s.daraja_environment, 'production')) = 'sandbox'
       then 'sandbox' else 'production' end,
  'active',
  'https://ixxnjxqwbpetdituqvyp.supabase.co/functions/v1/patafix-c2b-validation',
  'https://ixxnjxqwbpetdituqvyp.supabase.co/functions/v1/patafix-payment-callback',
  coalesce(s.updated_at, now())
from public.loan_settings s
where nullif(trim(s.mpesa_shortcode), '') is not null
on conflict (business_id, provider) do update
set shortcode = excluded.shortcode,
    environment = excluded.environment,
    status = 'active',
    validation_url = excluded.validation_url,
    confirmation_url = excluded.confirmation_url,
    updated_at = now();

alter table public.patafix_payment_routes enable row level security;
drop policy if exists patafix_payment_routes_select on public.patafix_payment_routes;
create policy patafix_payment_routes_select
on public.patafix_payment_routes for select to authenticated
using (public.patafix_can_access_business(business_id));

revoke insert, update, delete on public.patafix_payment_routes from anon, authenticated;
grant select on public.patafix_payment_routes to authenticated;
grant all on public.patafix_payment_routes to service_role;

-- Credit tables were introduced after the main multi-business migration and
-- still used the older single-business helper. Use membership-aware isolation.
do $$
declare v_table text;
begin
  foreach v_table in array array['patafix_credit_profiles','patafix_credit_events'] loop
    if to_regclass('public.' || v_table) is not null then
      execute format('alter table public.%I enable row level security', v_table);
      execute format('drop policy if exists patafix_business_select on public.%I', v_table);
      execute format('drop policy if exists patafix_business_insert on public.%I', v_table);
      execute format('drop policy if exists patafix_business_update on public.%I', v_table);
      execute format('drop policy if exists patafix_business_delete on public.%I', v_table);
      execute format('drop policy if exists patafix_tenant_select on public.%I', v_table);
      execute format('create policy patafix_tenant_select on public.%I for select to authenticated using (public.patafix_can_access_business(business_id))', v_table);
    end if;
  end loop;
end $$;

-- Upload paths already begin with the business ID. Enforce that ownership for
-- writes while retaining the current public read behaviour for legacy photos.
drop policy if exists patafix_photo_insert on storage.objects;
create policy patafix_photo_insert on storage.objects for insert to authenticated
with check (
  bucket_id in ('patafix-client-photos','patafix-client-assets')
  and public.patafix_can_access_business((storage.foldername(name))[1])
);

drop policy if exists patafix_photo_update on storage.objects;
create policy patafix_photo_update on storage.objects for update to authenticated
using (
  bucket_id in ('patafix-client-photos','patafix-client-assets')
  and public.patafix_can_access_business((storage.foldername(name))[1])
)
with check (
  bucket_id in ('patafix-client-photos','patafix-client-assets')
  and public.patafix_can_access_business((storage.foldername(name))[1])
);

drop policy if exists patafix_photo_delete on storage.objects;
create policy patafix_photo_delete on storage.objects for delete to authenticated
using (
  bucket_id in ('patafix-client-photos','patafix-client-assets')
  and public.patafix_can_access_business((storage.foldername(name))[1])
);

commit;

select
  'PataFix Phase 2 isolation ready' as status,
  (select count(*) from public.patafix_payment_routes) as payment_routes,
  (select count(*) from public.patafix_platform_businesses) as platform_businesses,
  (select count(*) from public.loan_settings where nullif(trim(mpesa_shortcode),'') is not null) as configured_shortcodes;
