-- NOX7 multi-alliance migration: stage 15 (selected profile data reader)
-- Read-only profile data for the authenticated account's selected active profile.
-- Existing NOX7 functions and tables are not removed or rewritten.

begin;

create or replace function public.alliance_get_own_profile_data(
  p_profile_id uuid
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
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if not public.nox7_owns_active_profile(p_profile_id) then
    raise exception 'Dieses aktive Spielerprofil gehört nicht zu deinem Konto oder ist nicht verfügbar';
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
  where p.id = p_profile_id
    and p.status = 'active';
end;
$function$;

revoke all on function public.alliance_get_own_profile_data(uuid) from public, anon;
grant execute on function public.alliance_get_own_profile_data(uuid) to authenticated;

commit;

-- Verification (run separately):
-- SELECT
--   to_regprocedure('public.alliance_get_own_profile_data(uuid)') IS NOT NULL AS funktion_vorhanden,
--   has_function_privilege('authenticated','public.alliance_get_own_profile_data(uuid)','EXECUTE') AS angemeldet_erlaubt,
--   has_function_privilege('anon','public.alliance_get_own_profile_data(uuid)','EXECUTE') AS anonym_erlaubt,
--   has_function_privilege('public','public.alliance_get_own_profile_data(uuid)','EXECUTE') AS public_erlaubt;
-- Expected: true, true, false, false.
