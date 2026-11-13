-- Run after patafix-platform-control-plane.sql.
-- Replace the placeholder with the email address you will use to sign in to
-- the private platform console. The user must already exist in Supabase Auth.

do $$
declare
  v_owner_email constant text := 'REPLACE_WITH_OWNER_EMAIL';
  v_owner_name constant text := 'Platform Owner';
  v_auth_user_id uuid;
begin
  if v_owner_email = 'REPLACE_WITH_OWNER_EMAIL'
     or nullif(btrim(v_owner_email), '') is null then
    raise exception 'Replace REPLACE_WITH_OWNER_EMAIL with the platform owner email before running this script.';
  end if;

  select u.id
    into v_auth_user_id
  from auth.users u
  where lower(u.email) = lower(btrim(v_owner_email))
  order by u.created_at
  limit 1;

  if v_auth_user_id is null then
    raise exception 'No Supabase Auth user exists for %. Create/sign up that user first, then run this script again.', v_owner_email;
  end if;

  insert into public.patafix_platform_admins (
    auth_user_id,
    email,
    full_name,
    is_active
  )
  values (
    v_auth_user_id,
    lower(btrim(v_owner_email)),
    v_owner_name,
    true
  )
  on conflict (auth_user_id) do update
  set email = excluded.email,
      full_name = coalesce(nullif(public.patafix_platform_admins.full_name, ''), excluded.full_name),
      is_active = true,
      updated_at = now();
end $$;

select
  a.email,
  a.full_name,
  a.is_active,
  a.created_at,
  'Platform owner access ready' as status
from public.patafix_platform_admins a
where lower(a.email) = lower('REPLACE_WITH_OWNER_EMAIL');
