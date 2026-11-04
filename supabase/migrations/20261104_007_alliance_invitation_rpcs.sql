-- NOX7 multi-alliance migration: stage 7 (alliance invitation RPCs)
-- Adds secure, alliance-scoped invitation creation, join requests, review,
-- listing and revocation. Existing NOX7 signup functions and frontend are
-- deliberately left unchanged until the new frontend flow is ready.

begin;

-- Supabase normally installs pgcrypto in the extensions schema. Fail with a
-- clear message rather than silently falling back to weak invitation hashes.
do $preflight$
begin
  if to_regprocedure('extensions.digest(bytea,text)') is null
     or to_regprocedure('extensions.gen_random_bytes(integer)') is null then
    raise exception
      'Migration 007 requires pgcrypto functions extensions.digest and extensions.gen_random_bytes. Enable pgcrypto in Supabase Database Extensions, then rerun.';
  end if;
end
$preflight$;

-- Create a one-time-visible invitation code. Only an R5 of the target alliance
-- (or the fixed platform administrator) can create codes for that alliance.
create or replace function public.create_alliance_invitation(
  p_alliance_id uuid,
  p_max_uses integer default 1,
  p_expires_at timestamptz default null
)
returns table (
  invitation_id uuid,
  invitation_code text,
  expires_at timestamptz,
  max_uses integer
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_code text;
  v_hash text;
  v_creator_profile_id uuid;
  v_invitation_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_max_uses is null or p_max_uses < 1 or p_max_uses > 500 then
    raise exception 'Die maximale Verwendung muss zwischen 1 und 500 liegen';
  end if;

  if p_expires_at is not null and p_expires_at <= now() then
    raise exception 'Das Ablaufdatum muss in der Zukunft liegen';
  end if;

  if not public.nox7_can_manage_alliance(p_alliance_id, 'R5') then
    raise exception 'Nur der R5 oder Plattformadministrator darf Einladungscodes erstellen';
  end if;

  select p.id
    into v_creator_profile_id
  from public.profiles p
  where p.owner_id = auth.uid()
    and p.alliance_id = p_alliance_id
    and p.status = 'active'
  order by case p.game_rank when 'R5' then 0 else 1 end
  limit 1;

  if v_creator_profile_id is null then
    select p.id
      into v_creator_profile_id
    from public.profiles p
    where p.owner_id = auth.uid()
      and p.role = 'admin'
      and p.status = 'active'
    order by p.created_at
    limit 1;
  end if;

  if v_creator_profile_id is null then
    raise exception 'Erstellerprofil konnte nicht ermittelt werden';
  end if;

  v_code := 'NOX-' || upper(encode(extensions.gen_random_bytes(18), 'hex'));
  v_hash := encode(extensions.digest(convert_to(v_code, 'UTF8'), 'sha256'), 'hex');

  insert into public.alliance_invitation_codes (
    alliance_id, code_hash, created_by_profile_id, expires_at, max_uses
  )
  values (
    p_alliance_id, v_hash, v_creator_profile_id, p_expires_at, p_max_uses
  )
  returning id into v_invitation_id;

  return query
  select v_invitation_id, v_code, p_expires_at, p_max_uses;
end;
$function$;

-- Return invitation metadata only. The original plaintext code is never
-- stored and therefore cannot be retrieved after creation.
create or replace function public.list_alliance_invitation_codes(
  p_alliance_id uuid
)
returns table (
  invitation_id uuid,
  created_at timestamptz,
  expires_at timestamptz,
  max_uses integer,
  uses_count integer,
  revoked_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if not public.nox7_can_manage_alliance(p_alliance_id, 'R5') then
    raise exception 'Keine Berechtigung für diese Allianz';
  end if;

  return query
  select c.id, c.created_at, c.expires_at, c.max_uses, c.uses_count, c.revoked_at
  from public.alliance_invitation_codes c
  where c.alliance_id = p_alliance_id
  order by c.created_at desc;
end;
$function$;

-- Revoke an invitation code without deleting its audit trail or join requests.
create or replace function public.revoke_alliance_invitation(
  p_alliance_id uuid,
  p_invitation_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if not public.nox7_can_manage_alliance(p_alliance_id, 'R5') then
    raise exception 'Keine Berechtigung für diese Allianz';
  end if;

  update public.alliance_invitation_codes
  set revoked_at = coalesce(revoked_at, now())
  where id = p_invitation_id
    and alliance_id = p_alliance_id;

  get diagnostics v_rows = row_count;
  return v_rows = 1;
end;
$function$;

-- An authenticated account can request a player profile in an additional
-- alliance. The code is locked while capacity is checked and consumed, so
-- simultaneous requests cannot exceed max_uses.
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
  v_owner_id uuid;
  v_email text;
  v_code text;
  v_code_hash text;
  v_invitation public.alliance_invitation_codes%rowtype;
  v_profile_id uuid;
  v_request_id uuid;
  v_existing_status text;
  v_display_name text;
begin
  v_owner_id := auth.uid();
  if v_owner_id is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  v_code := upper(btrim(coalesce(p_invitation_code, '')));
  v_display_name := btrim(coalesce(p_display_name, ''));

  if v_code = '' then
    raise exception 'Bitte einen Einladungscode eingeben';
  end if;

  if char_length(v_display_name) < 2 or char_length(v_display_name) > 40 then
    raise exception 'Der Spielername muss zwischen 2 und 40 Zeichen lang sein';
  end if;

  select lower(u.email)
    into v_email
  from auth.users u
  where u.id = v_owner_id;

  if v_email is null or v_email = '' then
    raise exception 'Für das Konto ist keine E-Mail-Adresse hinterlegt';
  end if;

  v_code_hash := encode(extensions.digest(convert_to(v_code, 'UTF8'), 'sha256'), 'hex');

  select c.*
    into v_invitation
  from public.alliance_invitation_codes c
  where c.code_hash = v_code_hash
  for update;

  if not found then
    raise exception 'Der Einladungscode ist ungültig';
  end if;

  if v_invitation.revoked_at is not null then
    raise exception 'Dieser Einladungscode wurde widerrufen';
  end if;

  if v_invitation.expires_at is not null and v_invitation.expires_at <= now() then
    raise exception 'Dieser Einladungscode ist abgelaufen';
  end if;

  if v_invitation.uses_count >= v_invitation.max_uses then
    raise exception 'Dieser Einladungscode wurde bereits vollständig verwendet';
  end if;

  select p.id, p.status
    into v_profile_id, v_existing_status
  from public.profiles p
  where p.owner_id = v_owner_id
    and p.alliance_id = v_invitation.alliance_id
  for update;

  if v_profile_id is not null and v_existing_status = 'active' then
    raise exception 'Dieses Konto besitzt bereits ein aktives Profil in dieser Allianz';
  end if;

  if v_profile_id is not null and v_existing_status = 'pending' then
    raise exception 'Für diese Allianz besteht bereits eine offene Beitrittsanfrage';
  end if;

  if v_profile_id is null then
    v_profile_id := gen_random_uuid();

    insert into public.profiles (
      id, owner_id, alliance_id, display_name, role, game_rank,
      status, archived_at, archive_reason, archived_by
    )
    values (
      v_profile_id, v_owner_id, v_invitation.alliance_id, v_display_name,
      'member', 'R1', 'pending', now(), 'pending', null
    );
  else
    update public.profiles
    set display_name = v_display_name,
        role = 'member',
        game_rank = 'R1',
        status = 'pending',
        archived_at = now(),
        archive_reason = 'pending',
        archived_by = null
    where id = v_profile_id;
  end if;

  insert into public.alliance_join_requests (
    owner_id, profile_id, alliance_id, invitation_id, email, status,
    requested_at, reviewed_by_profile_id, reviewed_at, review_note
  )
  values (
    v_owner_id, v_profile_id, v_invitation.alliance_id, v_invitation.id,
    v_email, 'pending', now(), null, null, null
  )
  on conflict (owner_id, alliance_id) do update
  set profile_id = excluded.profile_id,
      invitation_id = excluded.invitation_id,
      email = excluded.email,
      status = 'pending',
      requested_at = now(),
      reviewed_by_profile_id = null,
      reviewed_at = null,
      review_note = null
  returning id into v_request_id;

  update public.alliance_invitation_codes
  set uses_count = uses_count + 1
  where id = v_invitation.id;

  return jsonb_build_object(
    'ok', true,
    'message', 'Beitrittsanfrage wurde übermittelt und wartet auf Freigabe.',
    'request_id', v_request_id,
    'profile_id', v_profile_id,
    'alliance_id', v_invitation.alliance_id
  );
end;
$function$;

-- List pending join requests for R4/R5 of the same alliance.
create or replace function public.list_alliance_join_requests(
  p_alliance_id uuid,
  p_status text default 'pending'
)
returns table (
  request_id uuid,
  profile_id uuid,
  display_name text,
  email text,
  requested_at timestamptz,
  invitation_id uuid,
  request_status text
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_status not in ('pending', 'approved', 'rejected', 'all') then
    raise exception 'Ungültiger Anfragestatus';
  end if;

  if not public.nox7_can_manage_alliance(p_alliance_id, 'R4') then
    raise exception 'Keine Berechtigung für diese Allianz';
  end if;

  return query
  select r.id, r.profile_id, p.display_name, r.email,
         r.requested_at, r.invitation_id, r.status
  from public.alliance_join_requests r
  join public.profiles p on p.id = r.profile_id
  where r.alliance_id = p_alliance_id
    and (p_status = 'all' or r.status = p_status)
  order by r.requested_at desc;
end;
$function$;

-- R4/R5 may review requests only inside their own alliance. Approval activates
-- the R1 profile; rejection archives it and releases one invitation use.
create or replace function public.review_alliance_join_request(
  p_request_id uuid,
  p_approve boolean,
  p_review_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_request public.alliance_join_requests%rowtype;
  v_actor_profile_id uuid;
  v_note text;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  select r.*
    into v_request
  from public.alliance_join_requests r
  where r.id = p_request_id
  for update;

  if not found then
    raise exception 'Beitrittsanfrage nicht gefunden';
  end if;

  if not public.nox7_can_manage_alliance(v_request.alliance_id, 'R4') then
    raise exception 'Keine Berechtigung für diese Allianz';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'Diese Beitrittsanfrage wurde bereits bearbeitet';
  end if;

  v_note := nullif(btrim(coalesce(p_review_note, '')), '');
  if v_note is not null and char_length(v_note) > 500 then
    raise exception 'Die Notiz darf maximal 500 Zeichen enthalten';
  end if;

  select p.id
    into v_actor_profile_id
  from public.profiles p
  where p.owner_id = auth.uid()
    and p.alliance_id = v_request.alliance_id
    and p.status = 'active'
    and p.game_rank in ('R4', 'R5')
  order by case p.game_rank when 'R5' then 0 else 1 end
  limit 1;

  if v_actor_profile_id is null then
    select p.id
      into v_actor_profile_id
    from public.profiles p
    where p.owner_id = auth.uid()
      and p.role = 'admin'
      and p.status = 'active'
    order by p.created_at
    limit 1;
  end if;

  if p_approve then
    update public.profiles
    set status = 'active',
        archived_at = null,
        archive_reason = null,
        archived_by = null,
        game_rank = 'R1',
        role = 'member'
    where id = v_request.profile_id
      and owner_id = v_request.owner_id
      and alliance_id = v_request.alliance_id
      and status = 'pending';

    update public.alliance_join_requests
    set status = 'approved',
        reviewed_by_profile_id = v_actor_profile_id,
        reviewed_at = now(),
        review_note = v_note
    where id = v_request.id;

    return jsonb_build_object(
      'ok', true,
      'status', 'approved',
      'profile_id', v_request.profile_id,
      'alliance_id', v_request.alliance_id
    );
  else
    update public.profiles
    set status = 'rejected',
        archived_at = now(),
        archive_reason = 'rejected',
        archived_by = v_actor_profile_id
    where id = v_request.profile_id
      and owner_id = v_request.owner_id
      and alliance_id = v_request.alliance_id
      and status = 'pending';

    update public.alliance_join_requests
    set status = 'rejected',
        reviewed_by_profile_id = v_actor_profile_id,
        reviewed_at = now(),
        review_note = v_note
    where id = v_request.id;

    update public.alliance_invitation_codes
    set uses_count = greatest(uses_count - 1, 0)
    where id = v_request.invitation_id;

    return jsonb_build_object(
      'ok', true,
      'status', 'rejected',
      'profile_id', v_request.profile_id,
      'alliance_id', v_request.alliance_id
    );
  end if;
end;
$function$;

-- Expose only the RPCs to authenticated sessions. Underlying tables remain
-- inaccessible directly to anon/authenticated roles.
revoke all on function public.create_alliance_invitation(uuid, integer, timestamptz) from public, anon;
revoke all on function public.list_alliance_invitation_codes(uuid) from public, anon;
revoke all on function public.revoke_alliance_invitation(uuid, uuid) from public, anon;
revoke all on function public.request_alliance_join(text, text) from public, anon;
revoke all on function public.list_alliance_join_requests(uuid, text) from public, anon;
revoke all on function public.review_alliance_join_request(uuid, boolean, text) from public, anon;

grant execute on function public.create_alliance_invitation(uuid, integer, timestamptz) to authenticated;
grant execute on function public.list_alliance_invitation_codes(uuid) to authenticated;
grant execute on function public.revoke_alliance_invitation(uuid, uuid) to authenticated;
grant execute on function public.request_alliance_join(text, text) to authenticated;
grant execute on function public.list_alliance_join_requests(uuid, text) to authenticated;
grant execute on function public.review_alliance_join_request(uuid, boolean, text) to authenticated;

commit;

-- Verification (run separately after applying):
-- select
--   to_regprocedure('public.create_alliance_invitation(uuid,integer,timestamptz)') is not null as create_invitation,
--   to_regprocedure('public.list_alliance_invitation_codes(uuid)') is not null as list_invitations,
--   to_regprocedure('public.revoke_alliance_invitation(uuid,uuid)') is not null as revoke_invitation,
--   to_regprocedure('public.request_alliance_join(text,text)') is not null as request_join,
--   to_regprocedure('public.list_alliance_join_requests(uuid,text)') is not null as list_join_requests,
--   to_regprocedure('public.review_alliance_join_request(uuid,boolean,text)') is not null as review_join_request;
--
-- These SECURITY DEFINER functions require a valid authenticated JWT for use.
-- Do not test their authorization behavior from the SQL Editor, where auth.uid()
-- is normally NULL. Test through an authenticated client before enabling UI.
