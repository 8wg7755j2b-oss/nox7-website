-- Allow Supabase dashboard email invitations to be created without a NOX7 player name.
-- This is only for Auth users created through inviteUserByEmail (invited_at is set).
-- Normal username-only signup and alliance invitation signup keep their existing checks.
begin;

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
  -- Dashboard/API email invitations are standalone Auth accounts for email-delivery testing.
  -- Do not create a game profile or require a player name for these accounts.
  if new.invited_at is not null then
    return new;
  end if;

  if coalesce(new.raw_user_meta_data->>'account_only_signup','false')='true' then
    return new;
  end if;

  requested_name:=nullif(btrim(new.raw_user_meta_data->>'display_name'),'');
  if requested_name is null or char_length(requested_name) not between 2 and 40 then
    raise exception 'Bitte einen gültigen Spielernamen angeben.';
  end if;

  if coalesce(new.raw_user_meta_data->>'multi_alliance_signup','false')='true' then
    select r.* into v_reservation
    from public.alliance_invitation_reservations r
    where lower(r.email)=lower(new.email) and r.expires_at>now()
    order by r.reserved_at desc limit 1 for update;

    if not found then
      raise exception 'Die Einladung ist nicht mehr reserviert. Bitte erneut prüfen.';
    end if;

    select c.* into v_invitation
    from public.alliance_invitation_codes c
    where c.id=v_reservation.invitation_id
      and c.alliance_id=v_reservation.alliance_id
    for update;

    if not found or v_invitation.revoked_at is not null
      or (v_invitation.expires_at is not null and v_invitation.expires_at<=now())
      or v_invitation.uses_count>=v_invitation.max_uses then
      raise exception 'Die Einladung ist nicht mehr gültig oder vollständig verwendet.';
    end if;

    v_profile_id:=gen_random_uuid();

    insert into public.profiles(
      id,owner_id,alliance_id,display_name,role,game_rank,status,
      archived_at,archive_reason,archived_by
    )
    values(
      v_profile_id,new.id,v_reservation.alliance_id,requested_name,
      'member','R1','pending',now(),'pending',null
    );

    insert into public.alliance_join_requests(
      owner_id,profile_id,alliance_id,invitation_id,email,status,requested_at
    )
    values(
      new.id,v_profile_id,v_reservation.alliance_id,
      v_reservation.invitation_id,lower(new.email),'pending',now()
    );

    update public.alliance_invitation_codes
    set uses_count=uses_count+1
    where id=v_reservation.invitation_id;

    delete from public.alliance_invitation_reservations
    where lower(email)=lower(new.email);

    return new;
  end if;

  select a.id into strict v_nox7_alliance_id
  from public.alliances a
  where a.slug='nox7';

  insert into public.profiles(id,owner_id,alliance_id,display_name,role,game_rank)
  values(new.id,new.id,v_nox7_alliance_id,requested_name,'member','R1');

  return new;
end;
$function$;

commit;
