-- NOX7 migration 028: profile data reader for alliance members
-- Allows R4/R5 in the selected alliance and the primary platform admin
-- to read an active member's full profile data. Members read their own
-- profile through alliance_get_own_profile_data.

begin;

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
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if public.nox7_is_primary_admin() then
    select p.alliance_id
      into v_alliance_id
    from public.profiles p
    where p.id = p_target_profile_id
      and p.status = 'active'
      and p.role <> 'admin';
  else
    select actor.alliance_id
      into v_alliance_id
    from public.profiles actor
    join public.profiles target
      on target.alliance_id = actor.alliance_id
    where actor.id = p_actor_profile_id
      and actor.owner_id = auth.uid()
      and actor.status = 'active'
      and actor.game_rank in ('R4','R5')
      and target.id = p_target_profile_id
      and target.status = 'active'
      and target.role <> 'admin';
  end if;

  if v_alliance_id is null then
    raise exception 'Keine Berechtigung für dieses Mitglied oder diese Allianz';
  end if;

  return query
  select
    p.id,
    p.display_name,
    p.game_rank,
    p.role,
    p.power,
    p.squad1_power,
    p.squad1_type,
    p.squad2_power,
    p.squad2_type,
    p.squad3_power,
    p.squad3_type,
    p.squad_heroes
  from public.profiles p
  where p.id = p_target_profile_id
    and p.alliance_id = v_alliance_id
    and p.status = 'active'
    and p.role <> 'admin';
end;
$function$;

revoke all on function public.alliance_get_member_profile_data(uuid,uuid) from public, anon;
grant execute on function public.alliance_get_member_profile_data(uuid,uuid) to authenticated;

commit;

-- Verification:
-- select
--   to_regprocedure('public.alliance_get_member_profile_data(uuid,uuid)') is not null as funktion_vorhanden,
--   has_function_privilege('authenticated','public.alliance_get_member_profile_data(uuid,uuid)','EXECUTE') as angemeldet_erlaubt,
--   has_function_privilege('anon','public.alliance_get_member_profile_data(uuid,uuid)','EXECUTE') as anonym_erlaubt;
-- Expected: true | true | false
