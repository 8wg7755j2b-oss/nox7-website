-- Platform admin: create an additional active player profile for an existing account.
begin;

create or replace function public.platform_admin_create_profile(
  p_user_id uuid,
  p_alliance_id uuid,
  p_display_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_profile_id uuid := gen_random_uuid();
  v_name text := btrim(coalesce(p_display_name, ''));
  v_alliance_name text;
  v_username text;
begin
  perform public.platform_admin_guard();

  if p_user_id is null or p_alliance_id is null then
    raise exception 'Konto und Allianz müssen ausgewählt sein.';
  end if;

  if p_user_id = '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid then
    raise exception 'Für das geschützte Plattformadministrator-Konto kann diese Funktion nicht verwendet werden.';
  end if;

  if char_length(v_name) not between 2 and 40 then
    raise exception 'Spielername muss 2 bis 40 Zeichen haben.';
  end if;

  select coalesce(
    nullif(btrim(u.raw_user_meta_data->>'username'), ''),
    split_part(coalesce(u.email, ''), '@', 1)
  )
  into v_username
  from auth.users u
  where u.id = p_user_id;

  if not found then
    raise exception 'Das Benutzerkonto wurde nicht gefunden.';
  end if;

  select a.name into v_alliance_name
  from public.alliances a
  where a.id = p_alliance_id and a.is_enabled = true;

  if not found then
    raise exception 'Allianz nicht gefunden oder deaktiviert.';
  end if;

  if exists (
    select 1 from public.profiles p
    where p.owner_id = p_user_id and p.alliance_id = p_alliance_id
  ) then
    raise exception 'Dieses Konto besitzt bereits ein Spielerprofil in dieser Allianz.';
  end if;

  if exists (
    select 1 from public.profiles p
    where p.alliance_id = p_alliance_id
      and lower(btrim(p.display_name)) = lower(v_name)
  ) then
    raise exception 'Dieser Spielername wird in der ausgewählten Allianz bereits verwendet.';
  end if;

  insert into public.profiles (
    id, owner_id, alliance_id, display_name, role, game_rank, status,
    archived_at, archive_reason, archived_by, platform_locked
  )
  values (
    v_profile_id, p_user_id, p_alliance_id, v_name, 'member', 'R1', 'active',
    null, null, null, false
  );

  perform public.platform_admin_log(
    'profile.create',
    'profile',
    v_profile_id::text,
    jsonb_build_object(
      'owner_id', p_user_id,
      'username', v_username,
      'alliance_id', p_alliance_id,
      'alliance_name', v_alliance_name,
      'display_name', v_name,
      'status', 'active'
    )
  );

  return v_profile_id;
end;
$function$;

revoke all on function public.platform_admin_create_profile(uuid, uuid, text) from public, anon;
grant execute on function public.platform_admin_create_profile(uuid, uuid, text) to authenticated;

commit;
