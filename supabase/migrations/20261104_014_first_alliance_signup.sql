-- NOX7 multi-alliance migration: stage 14 (first-alliance signup reservation)
-- Adds an email-bound, short-lived invitation reservation for unauthenticated
-- signups and extends handle_new_user without breaking the legacy NOX7 flow.
-- New frontend signups must set user_metadata.multi_alliance_signup = true.
-- The invitation code itself is never stored in auth user metadata.

begin;

create or replace function public.reserve_alliance_signup(
  p_email text,
  p_invitation_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_code text := upper(btrim(coalesce(p_invitation_code, '')));
  v_hash text;
  v_invitation public.alliance_invitation_codes%rowtype;
  v_reserved integer;
begin
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Bitte eine gültige E-Mail-Adresse eingeben';
  end if;

  if char_length(v_code) < 10 or char_length(v_code) > 100 then
    raise exception 'Der Einladungscode ist ungültig';
  end if;

  if exists (
    select 1 from auth.users u where lower(u.email) = v_email
  ) then
    raise exception 'Für diese E-Mail-Adresse besteht bereits ein Konto. Bitte anmelden.';
  end if;

  v_hash := encode(
    extensions.digest(convert_to(v_code, 'UTF8'), 'sha256'),
    'hex'
  );

  select c.*
    into v_invitation
  from public.alliance_invitation_codes c
  where c.code_hash = v_hash
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

  delete from public.alliance_invitation_reservations r
  where r.invitation_id = v_invitation.id
    and r.expires_at <= now();

  -- A given email can reserve only one first-alliance invitation at a time.
  delete from public.alliance_invitation_reservations r
  where lower(r.email) = v_email
    and r.alliance_id <> v_invitation.alliance_id;

  select count(*)::integer
    into v_reserved
  from public.alliance_invitation_reservations r
  where r.invitation_id = v_invitation.id
    and r.expires_at > now()
    and lower(r.email) <> v_email;

  if v_invitation.uses_count + v_reserved >= v_invitation.max_uses
     and not exists (
       select 1
       from public.alliance_invitation_reservations r
       where r.invitation_id = v_invitation.id
         and lower(r.email) = v_email
         and r.expires_at > now()
     ) then
    raise exception 'Dieser Einladungscode wurde bereits vollständig reserviert';
  end if;

  insert into public.alliance_invitation_reservations (
    email, alliance_id, invitation_id, reserved_at, expires_at
  )
  values (
    v_email, v_invitation.alliance_id, v_invitation.id, now(), now() + interval '30 minutes'
  )
  on conflict (email, alliance_id) do update
  set invitation_id = excluded.invitation_id,
      reserved_at = excluded.reserved_at,
      expires_at = excluded.expires_at;

  return jsonb_build_object(
    'ok', true,
    'message', 'Einladung bestätigt. Du kannst jetzt dein Konto erstellen.',
    'alliance_id', v_invitation.alliance_id,
    'expires_at', now() + interval '30 minutes'
  );
end;
$function$;

-- New accounts use their reserved invitation to create their first alliance
-- profile. Legacy signups without the marker retain the original NOX7 path
-- until the new frontend is deployed.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  requested_name text;
  v_nox7_alliance_id uuid;
  v_reservation public.alliance_invitation_reservations%rowtype;
  v_invitation public.alliance_invitation_codes%rowtype;
  v_profile_id uuid;
begin
  requested_name := nullif(
    btrim(new.raw_user_meta_data->>'display_name'),
    ''
  );

  if requested_name is null
     or char_length(requested_name) < 2
     or char_length(requested_name) > 40 then
    raise exception 'Bitte einen gültigen Spielernamen angeben.';
  end if;

  if coalesce(new.raw_user_meta_data->>'multi_alliance_signup', 'false') = 'true' then
    select r.*
      into v_reservation
    from public.alliance_invitation_reservations r
    where lower(r.email) = lower(new.email)
      and r.expires_at > now()
    order by r.reserved_at desc
    limit 1
    for update;

    if not found then
      raise exception 'Die Einladung ist nicht mehr reserviert. Bitte erneut prüfen.';
    end if;

    select c.*
      into v_invitation
    from public.alliance_invitation_codes c
    where c.id = v_reservation.invitation_id
      and c.alliance_id = v_reservation.alliance_id
    for update;

    if not found
       or v_invitation.revoked_at is not null
       or (v_invitation.expires_at is not null and v_invitation.expires_at <= now())
       or v_invitation.uses_count >= v_invitation.max_uses then
      raise exception 'Die Einladung ist nicht mehr gültig oder vollständig verwendet.';
    end if;

    v_profile_id := gen_random_uuid();

    insert into public.profiles (
      id, owner_id, alliance_id, display_name, role, game_rank,
      status, archived_at, archive_reason, archived_by
    )
    values (
      v_profile_id, new.id, v_reservation.alliance_id, requested_name,
      'member', 'R1', 'pending', now(), 'pending', null
    );

    insert into public.alliance_join_requests (
      owner_id, profile_id, alliance_id, invitation_id, email, status,
      requested_at, reviewed_by_profile_id, reviewed_at, review_note
    )
    values (
      new.id, v_profile_id, v_reservation.alliance_id, v_reservation.invitation_id,
      lower(new.email), 'pending', now(), null, null, null
    );

    update public.alliance_invitation_codes
    set uses_count = uses_count + 1
    where id = v_reservation.invitation_id;

    delete from public.alliance_invitation_reservations
    where lower(email) = lower(new.email);

    return new;
  end if;

  -- Backward compatibility for the currently deployed NOX7 registration UI.
  select a.id
    into strict v_nox7_alliance_id
  from public.alliances a
  where a.slug = 'nox7';

  insert into public.profiles (
    id, owner_id, alliance_id, display_name, role, game_rank
  )
  values (
    new.id, new.id, v_nox7_alliance_id, requested_name, 'member', 'R1'
  );

  return new;
end;
$function$;

revoke all on function public.reserve_alliance_signup(text, text) from public;
grant execute on function public.reserve_alliance_signup(text, text) to anon, authenticated;

commit;

-- Verification (run separately after applying):
-- select
--   to_regprocedure('public.reserve_alliance_signup(text,text)') is not null
--     as signup_reservation_exists,
--   has_function_privilege('anon','public.reserve_alliance_signup(text,text)','EXECUTE')
--     as anonymous_can_reserve,
--   has_function_privilege('authenticated','public.reserve_alliance_signup(text,text)','EXECUTE')
--     as authenticated_can_reserve,
--   has_function_privilege('public','public.reserve_alliance_signup(text,text)','EXECUTE')
--     as public_role_can_reserve;
--
-- Expected: true, true, true, false.
-- Do not test the reservation with a real invitation until the new signup UI
-- is ready. The legacy signup path remains supported by the unchanged marker check.
