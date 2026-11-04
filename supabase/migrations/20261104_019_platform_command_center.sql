-- NOX7 Platform Command Center: complete platform administration layer.
-- Additive only. Existing alliance data and legacy RPCs remain intact.

begin;

alter table public.alliances
  add column if not exists is_enabled boolean not null default true;
alter table public.profiles
  add column if not exists platform_locked boolean not null default false;

create table if not exists public.platform_admin_audit (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id),
  action text not null,
  target_type text not null,
  target_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.platform_admin_audit enable row level security;
revoke all on public.platform_admin_audit from anon, authenticated;

create table if not exists public.platform_settings (
  setting_key text primary key,
  setting_value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);
alter table public.platform_settings enable row level security;
revoke all on public.platform_settings from anon, authenticated;

create or replace function public.platform_admin_guard()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is distinct from '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid then
    raise exception 'Keine Berechtigung für das Platform Command Center';
  end if;
end;
$function$;

create or replace function public.platform_admin_log(
  p_action text, p_target_type text, p_target_id text, p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform public.platform_admin_guard();
  insert into public.platform_admin_audit(actor_id,action,target_type,target_id,details)
  values(auth.uid(),left(p_action,80),left(p_target_type,40),p_target_id,coalesce(p_details,'{}'::jsonb));
end;
$function$;

create or replace function public.platform_admin_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare v jsonb;
begin
  perform public.platform_admin_guard();
  select jsonb_build_object(
    'alliances',(select count(*) from public.alliances),
    'enabled_alliances',(select count(*) from public.alliances where is_enabled),
    'profiles',(select count(*) from public.profiles),
    'active_profiles',(select count(*) from public.profiles where status='active'),
    'accounts',(select count(distinct owner_id) from public.profiles),
    'pending_requests',(select count(*) from public.alliance_join_requests where status='pending'),
    'active_invites',(select count(*) from public.alliance_invitation_codes where revoked_at is null and (expires_at is null or expires_at>now()) and uses_count<max_uses)
  ) into v;
  return v;
end;
$function$;

create or replace function public.platform_admin_alliances()
returns table(alliance_id uuid, alliance_name text, alliance_slug text, is_enabled boolean, member_count bigint, active_count bigint, pending_count bigint, created_at timestamptz)
language plpgsql stable security definer set search_path=''
as $function$
begin
  perform public.platform_admin_guard();
  return query
  select a.id,a.name,a.slug,a.is_enabled,count(p.id),
    count(p.id) filter(where p.status='active'),
    (select count(*) from public.alliance_join_requests r where r.alliance_id=a.id and r.status='pending'),
    a.created_at
  from public.alliances a left join public.profiles p on p.alliance_id=a.id
  group by a.id order by a.name;
end;
$function$;

create or replace function public.platform_admin_profiles()
returns table(profile_id uuid, alliance_id uuid, alliance_name text, display_name text, game_rank text, profile_role text, profile_status text, platform_locked boolean, owner_id uuid, account_email text, power bigint, created_at timestamptz)
language plpgsql stable security definer set search_path=''
as $function$
begin
  perform public.platform_admin_guard();
  return query
  select p.id,p.alliance_id,a.name,p.display_name,p.game_rank,p.role,p.status,p.platform_locked,p.owner_id,u.email,p.power,p.created_at
  from public.profiles p
  left join public.alliances a on a.id=p.alliance_id
  left join auth.users u on u.id=p.owner_id
  order by a.name nulls last,p.display_name;
end;
$function$;

create or replace function public.platform_admin_join_requests()
returns table(request_id uuid, alliance_id uuid, alliance_name text, profile_id uuid, display_name text, email text, request_status text, requested_at timestamptz, review_note text)
language plpgsql stable security definer set search_path=''
as $function$
begin
  perform public.platform_admin_guard();
  return query
  select r.id,r.alliance_id,a.name,r.profile_id,p.display_name,r.email,r.status,r.requested_at,r.review_note
  from public.alliance_join_requests r
  join public.alliances a on a.id=r.alliance_id
  join public.profiles p on p.id=r.profile_id
  order by case when r.status='pending' then 0 else 1 end,r.requested_at desc;
end;
$function$;

create or replace function public.platform_admin_invites()
returns table(invitation_id uuid, alliance_id uuid, alliance_name text, created_at timestamptz, expires_at timestamptz, max_uses integer, uses_count integer, revoked_at timestamptz)
language plpgsql stable security definer set search_path=''
as $function$
begin
  perform public.platform_admin_guard();
  return query
  select c.id,c.alliance_id,a.name,c.created_at,c.expires_at,c.max_uses,c.uses_count,c.revoked_at
  from public.alliance_invitation_codes c join public.alliances a on a.id=c.alliance_id
  order by c.created_at desc;
end;
$function$;

create or replace function public.platform_admin_create_alliance(p_name text,p_slug text)
returns uuid
language plpgsql security definer set search_path=''
as $function$
declare v_id uuid; v_name text:=btrim(coalesce(p_name,'')); v_slug text:=lower(btrim(coalesce(p_slug,'')));
begin
  perform public.platform_admin_guard();
  if char_length(v_name) not between 2 and 80 then raise exception 'Allianzname muss 2 bis 80 Zeichen haben'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then raise exception 'Slug: 3–40 Zeichen, Kleinbuchstaben, Zahlen und Bindestriche'; end if;
  insert into public.alliances(name,slug,is_enabled) values(v_name,v_slug,true) returning id into v_id;
  perform public.platform_admin_log('alliance.create','alliance',v_id::text,jsonb_build_object('name',v_name,'slug',v_slug));
  return v_id;
end;
$function$;

create or replace function public.platform_admin_update_alliance(p_alliance_id uuid,p_name text,p_slug text,p_enabled boolean)
returns void
language plpgsql security definer set search_path=''
as $function$
declare v_name text:=btrim(coalesce(p_name,'')); v_slug text:=lower(btrim(coalesce(p_slug,'')));
begin
  perform public.platform_admin_guard();
  if char_length(v_name) not between 2 and 80 then raise exception 'Allianzname muss 2 bis 80 Zeichen haben'; end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then raise exception 'Ungültiger Allianz-Slug'; end if;
  if p_enabled is null then raise exception 'Status fehlt'; end if;
  update public.alliances set name=v_name,slug=v_slug,is_enabled=p_enabled where id=p_alliance_id;
  if not found then raise exception 'Allianz nicht gefunden'; end if;
  perform public.platform_admin_log('alliance.update','alliance',p_alliance_id::text,jsonb_build_object('name',v_name,'slug',v_slug,'is_enabled',p_enabled));
end;
$function$;

create or replace function public.platform_admin_set_profile(p_profile_id uuid,p_rank text,p_locked boolean)
returns void
language plpgsql security definer set search_path=''
as $function$
declare v_alliance uuid; v_old_rank text; v_old_status text;
begin
  perform public.platform_admin_guard();
  if p_rank not in ('R1','R2','R3','R4','R5') then raise exception 'Ungültiger Rang'; end if;
  if p_locked is null then raise exception 'Sperrstatus fehlt'; end if;
  select alliance_id,game_rank,status into v_alliance,v_old_rank,v_old_status from public.profiles where id=p_profile_id for update;
  if v_alliance is null then raise exception 'Profil nicht gefunden'; end if;
  if p_rank='R5' and p_status='active' then
    update public.profiles set game_rank='R1' where alliance_id=v_alliance and id<>p_profile_id and game_rank='R5' and status='active';
  end if;
  update public.profiles set game_rank=p_rank,platform_locked=p_locked
  where id=p_profile_id;
  perform public.platform_admin_log('profile.update','profile',p_profile_id::text,jsonb_build_object('old_rank',v_old_rank,'rank',p_rank,'old_status',v_old_status,'platform_locked',p_locked));
end;
$function$;

create or replace function public.platform_admin_transfer_profile(p_profile_id uuid,p_new_owner_email text)
returns void
language plpgsql security definer set search_path=''
as $function$
declare v_new_owner uuid; v_alliance uuid; v_old_owner uuid;
begin
  perform public.platform_admin_guard();
  select id into v_new_owner from auth.users where lower(email)=lower(btrim(p_new_owner_email));
  if v_new_owner is null then raise exception 'Kein Konto mit dieser E-Mail-Adresse gefunden'; end if;
  select alliance_id,owner_id into v_alliance,v_old_owner from public.profiles where id=p_profile_id for update;
  if v_alliance is null then raise exception 'Profil nicht gefunden'; end if;
  if exists(select 1 from public.profiles where owner_id=v_new_owner and alliance_id=v_alliance and id<>p_profile_id) then
    raise exception 'Dieses Konto besitzt bereits ein Profil in dieser Allianz';
  end if;
  update public.profiles set owner_id=v_new_owner where id=p_profile_id;
  perform public.platform_admin_log('profile.transfer','profile',p_profile_id::text,jsonb_build_object('old_owner',v_old_owner,'new_owner',v_new_owner));
end;
$function$;

create or replace function public.platform_admin_review_request(p_request_id uuid,p_approve boolean,p_note text default null)
returns void
language plpgsql security definer set search_path=''
as $function$
declare r public.alliance_join_requests%rowtype;
begin
  perform public.platform_admin_guard();
  select * into r from public.alliance_join_requests where id=p_request_id for update;
  if not found then raise exception 'Beitrittsanfrage nicht gefunden'; end if;
  if r.status<>'pending' then raise exception 'Anfrage wurde bereits bearbeitet'; end if;
  if p_note is not null and char_length(p_note)>500 then raise exception 'Notiz maximal 500 Zeichen'; end if;
  if p_approve then
    update public.profiles set status='active',game_rank='R1',role='member',archived_at=null,archive_reason=null,archived_by=null
    where id=r.profile_id and owner_id=r.owner_id and alliance_id=r.alliance_id and status='pending';
    if not found then raise exception 'Profil konnte nicht aktiviert werden'; end if;
    update public.alliance_join_requests set status='approved',reviewed_by_profile_id=null,reviewed_at=now(),review_note=nullif(btrim(coalesce(p_note,'')),'') where id=r.id;
  else
    update public.profiles set status='rejected',archived_at=now(),archive_reason='rejected',archived_by=null where id=r.profile_id and status='pending';
    update public.alliance_join_requests set status='rejected',reviewed_by_profile_id=null,reviewed_at=now(),review_note=nullif(btrim(coalesce(p_note,'')),'') where id=r.id;
    update public.alliance_invitation_codes set uses_count=greatest(uses_count-1,0) where id=r.invitation_id;
  end if;
  perform public.platform_admin_log('join_request.review','join_request',r.id::text,jsonb_build_object('approved',p_approve,'alliance_id',r.alliance_id,'profile_id',r.profile_id));
end;
$function$;

create or replace function public.platform_admin_revoke_invite(p_invitation_id uuid)
returns void
language plpgsql security definer set search_path=''
as $function$
declare v_alliance uuid;
begin
  perform public.platform_admin_guard();
  update public.alliance_invitation_codes set revoked_at=coalesce(revoked_at,now()) where id=p_invitation_id returning alliance_id into v_alliance;
  if v_alliance is null then raise exception 'Einladungscode nicht gefunden'; end if;
  perform public.platform_admin_log('invite.revoke','invitation',p_invitation_id::text,jsonb_build_object('alliance_id',v_alliance));
end;
$function$;

create or replace function public.platform_admin_set_setting(p_key text,p_value jsonb)
returns void
language plpgsql security definer set search_path=''
as $function$
begin
  perform public.platform_admin_guard();
  if p_key is null or p_key !~ '^[a-z][a-z0-9_]{1,63}$' or p_value is null then raise exception 'Ungültige Systemeinstellung'; end if;
  insert into public.platform_settings(setting_key,setting_value,updated_at,updated_by)
  values(p_key,p_value,now(),auth.uid())
  on conflict(setting_key) do update set setting_value=excluded.setting_value,updated_at=now(),updated_by=auth.uid();
  perform public.platform_admin_log('setting.update','setting',p_key,jsonb_build_object('value',p_value));
end;
$function$;

create or replace function public.platform_admin_list_settings()
returns table(setting_key text,setting_value jsonb,updated_at timestamptz)
language plpgsql stable security definer set search_path=''
as $function$
begin
  perform public.platform_admin_guard();
  return query select s.setting_key,s.setting_value,s.updated_at from public.platform_settings s order by s.setting_key;
end;
$function$;

create or replace function public.platform_admin_audit_log()
returns table(audit_id uuid,action text,target_type text,target_id text,details jsonb,created_at timestamptz)
language plpgsql stable security definer set search_path=''
as $function$
begin
  perform public.platform_admin_guard();
  return query select l.id,l.action,l.target_type,l.target_id,l.details,l.created_at from public.platform_admin_audit l order by l.created_at desc limit 200;
end;
$function$;

revoke all on function public.platform_admin_guard() from public,anon;
revoke all on function public.platform_admin_log(text,text,text,jsonb) from public,anon;
grant execute on function public.platform_admin_guard() to authenticated;
grant execute on function public.platform_admin_log(text,text,text,jsonb) to authenticated;

revoke all on function public.platform_admin_dashboard() from public,anon;
revoke all on function public.platform_admin_alliances() from public,anon;
revoke all on function public.platform_admin_profiles() from public,anon;
revoke all on function public.platform_admin_join_requests() from public,anon;
revoke all on function public.platform_admin_invites() from public,anon;
revoke all on function public.platform_admin_create_alliance(text,text) from public,anon;
revoke all on function public.platform_admin_update_alliance(uuid,text,text,boolean) from public,anon;
revoke all on function public.platform_admin_set_profile(uuid,text,boolean) from public,anon;
revoke all on function public.platform_admin_transfer_profile(uuid,text) from public,anon;
revoke all on function public.platform_admin_review_request(uuid,boolean,text) from public,anon;
revoke all on function public.platform_admin_revoke_invite(uuid) from public,anon;
revoke all on function public.platform_admin_set_setting(text,jsonb) from public,anon;
revoke all on function public.platform_admin_list_settings() from public,anon;
revoke all on function public.platform_admin_audit_log() from public,anon;

grant execute on function public.platform_admin_dashboard() to authenticated;
grant execute on function public.platform_admin_alliances() to authenticated;
grant execute on function public.platform_admin_profiles() to authenticated;
grant execute on function public.platform_admin_join_requests() to authenticated;
grant execute on function public.platform_admin_invites() to authenticated;
grant execute on function public.platform_admin_create_alliance(text,text) to authenticated;
grant execute on function public.platform_admin_update_alliance(uuid,text,text,boolean) to authenticated;
grant execute on function public.platform_admin_set_profile(uuid,text,text) to authenticated;
grant execute on function public.platform_admin_transfer_profile(uuid,text) to authenticated;
grant execute on function public.platform_admin_review_request(uuid,boolean,text) to authenticated;
grant execute on function public.platform_admin_revoke_invite(uuid) to authenticated;
grant execute on function public.platform_admin_set_setting(text,jsonb) to authenticated;
grant execute on function public.platform_admin_list_settings() to authenticated;
grant execute on function public.platform_admin_audit_log() to authenticated;

commit;

-- Apply after migration 018. Verify using the authenticated application session.
