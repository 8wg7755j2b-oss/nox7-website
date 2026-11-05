-- Account-first registration and self-service alliance onboarding.
-- Apply after migrations 001-019.
begin;

alter table public.alliance_join_requests alter column invitation_id drop not null;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $function$
declare
  requested_name text;
  v_nox7_alliance_id uuid;
  v_reservation public.alliance_invitation_reservations%rowtype;
  v_invitation public.alliance_invitation_codes%rowtype;
  v_profile_id uuid;
begin
  if coalesce(new.raw_user_meta_data->>'account_only_signup','false')='true' then
    return new;
  end if;
  requested_name:=nullif(btrim(new.raw_user_meta_data->>'display_name'),'');
  if requested_name is null or char_length(requested_name) not between 2 and 40 then
    raise exception 'Bitte einen gültigen Spielernamen angeben.';
  end if;
  if coalesce(new.raw_user_meta_data->>'multi_alliance_signup','false')='true' then
    select r.* into v_reservation from public.alliance_invitation_reservations r
    where lower(r.email)=lower(new.email) and r.expires_at>now()
    order by r.reserved_at desc limit 1 for update;
    if not found then raise exception 'Die Einladung ist nicht mehr reserviert. Bitte erneut prüfen.'; end if;
    select c.* into v_invitation from public.alliance_invitation_codes c
    where c.id=v_reservation.invitation_id and c.alliance_id=v_reservation.alliance_id for update;
    if not found or v_invitation.revoked_at is not null
      or (v_invitation.expires_at is not null and v_invitation.expires_at<=now())
      or v_invitation.uses_count>=v_invitation.max_uses then
      raise exception 'Die Einladung ist nicht mehr gültig oder vollständig verwendet.';
    end if;
    v_profile_id:=gen_random_uuid();
    insert into public.profiles(id,owner_id,alliance_id,display_name,role,game_rank,status,archived_at,archive_reason,archived_by)
    values(v_profile_id,new.id,v_reservation.alliance_id,requested_name,'member','R1','pending',now(),'pending',null);
    insert into public.alliance_join_requests(owner_id,profile_id,alliance_id,invitation_id,email,status,requested_at)
    values(new.id,v_profile_id,v_reservation.alliance_id,v_reservation.invitation_id,lower(new.email),'pending',now());
    update public.alliance_invitation_codes set uses_count=uses_count+1 where id=v_reservation.invitation_id;
    delete from public.alliance_invitation_reservations where lower(email)=lower(new.email);
    return new;
  end if;
  select a.id into strict v_nox7_alliance_id from public.alliances a where a.slug='nox7';
  insert into public.profiles(id,owner_id,alliance_id,display_name,role,game_rank)
  values(new.id,new.id,v_nox7_alliance_id,requested_name,'member','R1');
  return new;
end;
$function$;

create or replace function public.create_alliance_for_account(p_name text,p_slug text,p_display_name text)
returns table(alliance_id uuid,profile_id uuid)
language plpgsql security definer set search_path=''
as $function$
declare
  v_alliance_id uuid;
  v_profile_id uuid:=gen_random_uuid();
  v_name text:=btrim(coalesce(p_name,''));
  v_slug text:=lower(btrim(coalesce(p_slug,'')));
  v_display_name text:=btrim(coalesce(p_display_name,''));
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  if char_length(v_name) not between 2 and 80 then raise exception 'Allianzname muss 2 bis 80 Zeichen haben'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then raise exception 'Allianz-Kürzel: 3 bis 40 Zeichen, Kleinbuchstaben, Zahlen und Bindestriche'; end if;
  if char_length(v_display_name) not between 2 and 40 then raise exception 'Spielername muss 2 bis 40 Zeichen haben'; end if;
  if exists(select 1 from public.profiles where owner_id=auth.uid() and status='active' and game_rank='R5') then
    raise exception 'Du führst bereits eine Allianz';
  end if;
  insert into public.alliances(name,slug,is_enabled) values(v_name,v_slug,true) returning id into v_alliance_id;
  insert into public.profiles(id,owner_id,alliance_id,display_name,role,game_rank,status)
  values(v_profile_id,auth.uid(),v_alliance_id,v_display_name,'member','R5','active');
  return query select v_alliance_id,v_profile_id;
end;
$function$;

create or replace function public.search_alliances(p_search text default null)
returns table(alliance_id uuid,alliance_name text,alliance_slug text,active_members bigint)
language sql stable security definer set search_path=''
as $function$
  select a.id,a.name,a.slug,count(p.id) filter(where p.status='active')
  from public.alliances a left join public.profiles p on p.alliance_id=a.id
  where auth.uid() is not null and a.is_enabled=true
    and (nullif(btrim(coalesce(p_search,'')),'') is null
      or a.name ilike '%'||btrim(p_search)||'%' or a.slug ilike '%'||btrim(p_search)||'%')
  group by a.id,a.name,a.slug order by a.name limit 50;
$function$;

create or replace function public.request_alliance_join_by_id(p_alliance_id uuid,p_display_name text)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_owner_id uuid:=auth.uid();
  v_email text;
  v_profile_id uuid;
  v_request_id uuid;
  v_status text;
  v_display_name text:=btrim(coalesce(p_display_name,''));
begin
  if v_owner_id is null then raise exception 'Anmeldung erforderlich'; end if;
  if char_length(v_display_name) not between 2 and 40 then raise exception 'Spielername muss 2 bis 40 Zeichen haben'; end if;
  if not exists(select 1 from public.alliances where id=p_alliance_id and is_enabled=true) then
    raise exception 'Allianz nicht gefunden oder derzeit nicht verfügbar';
  end if;
  select lower(u.email) into v_email from auth.users u where u.id=v_owner_id;
  if v_email is null then raise exception 'Für das Konto ist keine E-Mail-Adresse hinterlegt'; end if;
  select p.id,p.status into v_profile_id,v_status from public.profiles p
  where p.owner_id=v_owner_id and p.alliance_id=p_alliance_id for update;
  if v_profile_id is not null and v_status='active' then raise exception 'Du bist bereits Mitglied dieser Allianz'; end if;
  if v_profile_id is not null and v_status='pending' then raise exception 'Deine Beitrittsanfrage wartet bereits auf Freigabe'; end if;
  if v_profile_id is null then
    v_profile_id:=gen_random_uuid();
    insert into public.profiles(id,owner_id,alliance_id,display_name,role,game_rank,status,archived_at,archive_reason)
    values(v_profile_id,v_owner_id,p_alliance_id,v_display_name,'member','R1','pending',now(),'pending');
  else
    update public.profiles set display_name=v_display_name,role='member',game_rank='R1',
      status='pending',archived_at=now(),archive_reason='pending',archived_by=null where id=v_profile_id;
  end if;
  insert into public.alliance_join_requests(owner_id,profile_id,alliance_id,invitation_id,email,status,requested_at)
  values(v_owner_id,v_profile_id,p_alliance_id,null,v_email,'pending',now())
  on conflict(owner_id,alliance_id) do update set profile_id=excluded.profile_id,
    invitation_id=null,email=excluded.email,status='pending',requested_at=now(),
    reviewed_by_profile_id=null,reviewed_at=null,review_note=null
  returning id into v_request_id;
  return jsonb_build_object('ok',true,'message','Beitrittsanfrage wurde übermittelt und wartet auf Freigabe.',
    'request_id',v_request_id,'profile_id',v_profile_id,'alliance_id',p_alliance_id);
end;
$function$;

revoke all on function public.create_alliance_for_account(text,text,text) from public,anon;
revoke all on function public.search_alliances(text) from public,anon;
revoke all on function public.request_alliance_join_by_id(uuid,text) from public,anon;
grant execute on function public.create_alliance_for_account(text,text,text) to authenticated;
grant execute on function public.search_alliances(text) to authenticated;
grant execute on function public.request_alliance_join_by_id(uuid,text) to authenticated;
commit;
