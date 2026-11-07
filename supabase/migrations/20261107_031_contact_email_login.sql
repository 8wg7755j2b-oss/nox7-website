-- NOX7 migration 031: allow login with saved contact email
-- Resolves a unique contact email to the account's internal NOX7 auth address.
-- Only synthetic @nox7.invalid addresses are returned; the private contact email is never exposed.

create or replace function public.account_resolve_contact_login(p_contact_email text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_contact_email text := lower(trim(coalesce(p_contact_email, '')));
  v_match_count integer;
  v_login_email text;
begin
  if v_contact_email = '' or length(v_contact_email) > 254 then
    return null;
  end if;

  select count(*), min(lower(u.email))
    into v_match_count, v_login_email
  from auth.users u
  where lower(coalesce(u.raw_user_meta_data ->> 'contact_email', '')) = v_contact_email
    and lower(u.email) like '%@nox7.invalid';

  -- Do not resolve ambiguous contact addresses.
  if v_match_count <> 1 then
    return null;
  end if;

  return v_login_email;
end;
$function$;

revoke all on function public.account_resolve_contact_login(text) from public;
grant execute on function public.account_resolve_contact_login(text) to anon, authenticated;
