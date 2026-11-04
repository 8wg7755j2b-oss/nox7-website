-- NOX7 multi-alliance migration: stage 016 (alliance-scoped member directory)
-- Read-only member directory for the selected active alliance profile.
-- Does not change legacy tables, policies, or existing member records.

begin;

create or replace function public.alliance_list_members(
  p_actor_profile_id uuid
)
returns table (
  profile_id uuid,
  display_name text,
  game_rank text,
  profile_role text,
  power bigint,
  squad1_power bigint,
  squad2_power bigint,
  squad3_power bigint,
  squad1_type text,
  squad2_type text,
  squad3_type text
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

  select p.alliance_id
    into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.status = 'active';

  if v_alliance_id is null then
    raise exception 'Aktives Allianzprofil nicht gefunden';
  end if;

  return query
  select
    p.id,
    p.display_name,
    p.game_rank,
    p.role,
    p.power,
    p.squad1_power,
    p.squad2_power,
    p.squad3_power,
    p.squad1_type,
    p.squad2_type,
    p.squad3_type
  from public.profiles p
  where p.alliance_id = v_alliance_id
    and p.status = 'active'
  order by
    case p.game_rank
      when 'R5' then 1
      when 'R4' then 2
      when 'R3' then 3
      when 'R2' then 4
      when 'R1' then 5
      else 6
    end,
    p.power desc nulls last,
    p.display_name;
end;
$function$;

revoke all on function public.alliance_list_members(uuid) from public, anon;
grant execute on function public.alliance_list_members(uuid) to authenticated;

commit;

-- Verification (run separately after applying):
-- select
--   to_regprocedure('public.alliance_list_members(uuid)') is not null
--     as funktion_vorhanden,
--   has_function_privilege('authenticated',
--     'public.alliance_list_members(uuid)', 'EXECUTE')
--     as angemeldet_erlaubt,
--   has_function_privilege('anon',
--     'public.alliance_list_members(uuid)', 'EXECUTE')
--     as anonym_erlaubt,
--   has_function_privilege('public',
--     'public.alliance_list_members(uuid)', 'EXECUTE')
--     as public_erlaubt;
-- Expected: true | true | false | false
