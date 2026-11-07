-- Allow one account to own multiple distinct player profiles in the same alliance.
-- Each profile keeps its own approval request, statistics and history.
begin;

-- Remove the old one-profile-per-account-and-alliance restriction.
drop index if exists public.profiles_owner_alliance_uidx;

-- A join request is now unique by profile (already enforced by profile_id),
-- not by account + alliance. This permits multiple profiles for one account.
alter table public.alliance_join_requests
  drop constraint if exists alliance_join_requests_owner_alliance_key;

-- Self-service: create a fresh pending profile for every requested player name.
create or replace function public.request_alliance_join_by_id(
  p_alliance_id uuid,
  p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_owner_id uuid := auth.uid();
  v_email text;
  v_profile_id uuid := gen_random_uuid();
  v_request_id uuid;
  v_display_name text := btrim(coalesce(p_display_name, ''));
begin
  if v_owner_id is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if char_length(v_display_name) not between 2 and 40 then
    raise exception 'Spielername muss 2 bis 40 Zeichen haben';
  end if;

  if not exists (
    select 1 from public.alliances
    where id = p_alliance_id and is_enabled = true
  ) then
    raise exception 'Allianz nicht gefunden oder derzeit nicht verfügbar';
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = v_owner_id;

  if v_email is null then
    raise exception 'Für das Konto ist keine E-Mail-Adresse hinterlegt';
  end if;

  if exists (
    select 1 from public.profiles p
    where p.alliance_id = p_alliance_id
      and lower(btrim(p.display_name)) = lower(v_display_name)
  ) then
    raise exception 'Dieser Spielername wird in der Allianz bereits verwendet. Bitte einen anderen Namen eingeben.';
  end if;

  insert into public.profiles (
    id, owner_id, alliance_id, display_name, role, game_rank,
    status, archived_at, archive_reason, archived_by
  )
  values (
    v_profile_id, v_owner_id, p_alliance_id, v_display_name,
    'member', 'R1', 'pending', now(), 'pending', null
  );

  insert into public.alliance_join_requests (
    owner_id, profile_id, alliance_id, invitation_id, email, status, requested_at
  )
  values (
    v_owner_id, v_profile_id, p_alliance_id, null, v_email, 'pending', now()
  )
  returning id into v_request_id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Spielerprofil wurde angefragt und wartet auf Freigabe durch die Allianzführung.',
    'request_id', v_request_id,
    'profile_id', v_profile_id,
    'alliance_id', p_alliance_id
  );
end;
$function$;

-- Invitation-code flow: also creates a separate profile/request each time.
create or replace function public.request_alliance_join(
  p_invitation_code text,
  p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_owner_id uuid := auth.uid();
  v_email text;
  v_code text := upper(btrim(coalesce(p_invitation_code, '')));
  v_code_hash text;
  v_invitation public.alliance_invitation_codes%rowtype;
  v_profile_id uuid := gen_random_uuid();
  v_request_id uuid;
  v_display_name text := btrim(coalesce(p_display_name, ''));
begin
  if v_owner_id is null then
    raise exception 'Anmeldung erforderlich';
  end if;
  if v_code = '' then
    raise exception 'Bitte einen Einladungscode eingeben';
  end if;
  if char_length(v_display_name) not between 2 and 40 then
    raise exception 'Der Spielername muss zwischen 2 und 40 Zeichen lang sein';
  end if;

  select lower(u.email) into v_email
  from auth.users u where u.id = v_owner_id;
  if v_email is null or v_email = '' then
    raise exception 'Für das Konto ist keine E-Mail-Adresse hinterlegt';
  end if;

  v_code_hash := encode(
    extensions.digest(convert_to(v_code, 'UTF8'), 'sha256'), 'hex'
  );

  select c.* into v_invitation
  from public.alliance_invitation_codes c
  where c.code_hash = v_code_hash
  for update;

  if not found then raise exception 'Der Einladungscode ist ungültig'; end if;
  if v_invitation.revoked_at is not null then raise exception 'Dieser Einladungscode wurde widerrufen'; end if;
  if v_invitation.expires_at is not null and v_invitation.expires_at <= now() then
    raise exception 'Dieser Einladungscode ist abgelaufen';
  end if;
  if v_invitation.uses_count >= v_invitation.max_uses then
    raise exception 'Dieser Einladungscode wurde bereits vollständig verwendet';
  end if;

  if exists (
    select 1 from public.profiles p
    where p.alliance_id = v_invitation.alliance_id
      and lower(btrim(p.display_name)) = lower(v_display_name)
  ) then
    raise exception 'Dieser Spielername wird in der Allianz bereits verwendet. Bitte einen anderen Namen eingeben.';
  end if;

  insert into public.profiles (
    id, owner_id, alliance_id, display_name, role, game_rank,
    status, archived_at, archive_reason, archived_by
  )
  values (
    v_profile_id, v_owner_id, v_invitation.alliance_id, v_display_name,
    'member', 'R1', 'pending', now(), 'pending', null
  );

  insert into public.alliance_join_requests (
    owner_id, profile_id, alliance_id, invitation_id, email, status,
    requested_at, reviewed_by_profile_id, reviewed_at, review_note
  )
  values (
    v_owner_id, v_profile_id, v_invitation.alliance_id, v_invitation.id,
    v_email, 'pending', now(), null, null, null
  )
  returning id into v_request_id;

  update public.alliance_invitation_codes
  set uses_count = uses_count + 1
  where id = v_invitation.id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Spielerprofil wurde angefragt und wartet auf Freigabe durch die Allianzführung.',
    'request_id', v_request_id,
    'profile_id', v_profile_id,
    'alliance_id', v_invitation.alliance_id
  );
end;
$function$;

-- Platform administrator may also add multiple distinct profiles per account/alliance.
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
  ) into v_username
  from auth.users u where u.id = p_user_id;
  if not found then raise exception 'Das Benutzerkonto wurde nicht gefunden.'; end if;

  select a.name into v_alliance_name
  from public.alliances a
  where a.id = p_alliance_id and a.is_enabled = true;
  if not found then raise exception 'Allianz nicht gefunden oder deaktiviert.'; end if;

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
    'profile.create', 'profile', v_profile_id::text,
    jsonb_build_object(
      'owner_id', p_user_id, 'username', v_username,
      'alliance_id', p_alliance_id, 'alliance_name', v_alliance_name,
      'display_name', v_name, 'status', 'active'
    )
  );

  return v_profile_id;
end;
$function$;

revoke all on function public.request_alliance_join_by_id(uuid, text) from public, anon;
grant execute on function public.request_alliance_join_by_id(uuid, text) to authenticated;
revoke all on function public.request_alliance_join(text, text) from public, anon;
grant execute on function public.request_alliance_join(text, text) to authenticated;
revoke all on function public.platform_admin_create_profile(uuid, uuid, text) from public, anon;
grant execute on function public.platform_admin_create_profile(uuid, uuid, text) to authenticated;

commit;
