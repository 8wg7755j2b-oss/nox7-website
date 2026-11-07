-- Eigene Kontodaten: Benutzername ändern (interne Login-Adresse bleibt synchron)
create or replace function public.account_update_own_username(p_username text)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_uid uuid := auth.uid();
  v_username text := lower(trim(coalesce(p_username, '')));
  v_old_email text;
begin
  if v_uid is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if v_username !~ '^[a-z0-9._]{3,24}$' then
    raise exception 'Der Benutzername muss 3 bis 24 Zeichen haben und darf nur Kleinbuchstaben, Zahlen, Punkt und Unterstrich enthalten.';
  end if;

  if exists (
    select 1
    from auth.users u
    where u.id <> v_uid
      and lower(coalesce(u.raw_user_meta_data ->> 'username', '')) = v_username
  ) then
    raise exception 'Dieser Benutzername ist bereits vergeben.';
  end if;

  select u.email into v_old_email
  from auth.users u
  where u.id = v_uid
  for update;

  if v_old_email is null then
    raise exception 'Benutzerkonto nicht gefunden';
  end if;

  if v_old_email not like '%@nox7.invalid' then
    raise exception 'Dieses Konto verwendet keine interne NOX7-Anmeldeadresse. Bitte den Benutzernamen durch den Administrator ändern lassen.';
  end if;

  if exists (
    select 1 from auth.users u
    where u.id <> v_uid
      and lower(u.email) = lower(v_username || '@nox7.invalid')
  ) then
    raise exception 'Dieser Benutzername ist bereits vergeben.';
  end if;

  update auth.users
  set email = v_username || '@nox7.invalid',
      raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
        || jsonb_build_object('username', v_username)
  where id = v_uid;
end;
$function$;

revoke all on function public.account_update_own_username(text) from public, anon;
grant execute on function public.account_update_own_username(text) to authenticated;
