-- NOX7 migration 029: repair alliance news return type and member profile viewing
-- Fixes the posts RPC enum/text mismatch and lets active alliance members
-- view one another's profiles. Only R4/R5 and platform admin can edit profiles.

begin;

create or replace function public.alliance_list_posts(
  p_actor_profile_id uuid,
  p_limit integer default 30
)
returns table (
  post_id uuid,
  title text,
  body text,
  kind text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if not public.nox7_owns_active_profile(p_actor_profile_id) then
    raise exception 'Das ausgewählte aktive Spielerprofil gehört nicht zu diesem Konto';
  end if;

  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.status = 'active';

  if v_alliance_id is null then
    raise exception 'Aktives Allianzprofil nicht gefunden';
  end if;

  return query
  select n.id, n.title, n.body, n.kind::text, n.created_at
  from public.posts n
  where n.alliance_id = v_alliance_id
  order by n.created_at desc
  limit greatest(1, least(coalesce(p_limit,30),100));
end;
$function$;

create or replace function public.alliance_get_member_profile_data(
  p_actor_profile_id uuid,
  p_target_profile_id uuid
)
returns table (
  profile_id uuid,
  display_name text,
  game_rank text,
  profile_role text,
  power bigint,
  squad1_power bigint,
  squad1_type text,
  squad2_power bigint,
  squad2_type text,
  squad3_power bigint,
  squad3_type text,
  squad_heroes jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_is_platform_admin boolean;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  v_is_platform_admin := public.nox7_is_primary_admin();

  if v_is_platform_admin then
    select p.alliance_id into v_alliance_id
    from public.profiles p
    where p.id = p_target_profile_id
      and p.status = 'active';
  else
    select actor.alliance_id into v_alliance_id
    from public.profiles actor
    join public.profiles target
      on target.alliance_id = actor.alliance_id
    where actor.id = p_actor_profile_id
      and actor.owner_id = auth.uid()
      and actor.status = 'active'
      and target.id = p_target_profile_id
      and target.status = 'active'
      and (target.role <> 'admin' or target.owner_id = auth.uid());
  end if;

  if v_alliance_id is null then
    raise exception 'Keine Berechtigung für dieses Mitglied oder diese Allianz';
  end if;

  return query
  select
    p.id, p.display_name, p.game_rank, p.role, p.power,
    p.squad1_power, p.squad1_type,
    p.squad2_power, p.squad2_type,
    p.squad3_power, p.squad3_type,
    p.squad_heroes
  from public.profiles p
  where p.id = p_target_profile_id
    and p.alliance_id = v_alliance_id
    and p.status = 'active'
    and (p.role <> 'admin' or p.owner_id = auth.uid() or v_is_platform_admin);
end;
$function$;

revoke all on function public.alliance_list_posts(uuid,integer) from public, anon;
revoke all on function public.alliance_get_member_profile_data(uuid,uuid) from public, anon;
grant execute on function public.alliance_list_posts(uuid,integer) to authenticated;
grant execute on function public.alliance_get_member_profile_data(uuid,uuid) to authenticated;

commit;
