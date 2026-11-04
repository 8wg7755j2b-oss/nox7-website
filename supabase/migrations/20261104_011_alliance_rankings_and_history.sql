-- NOX7 multi-alliance migration: stage 11 (alliance-scoped rankings and history)
-- Read APIs use an explicitly selected active profile owned by auth.uid().
-- Legacy NOX7 functions and website remain untouched.

begin;

create or replace function public.alliance_get_power_ranking(
  p_actor_profile_id uuid,
  p_limit integer default 30
)
returns table (
  profile_id uuid,
  display_name text,
  game_rank text,
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
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';
  if v_alliance_id is null then
    raise exception 'Aktives Spielerprofil gehört nicht zu diesem Konto';
  end if;

  return query
  select p.id, p.display_name, p.game_rank, p.power,
         p.squad1_power, p.squad2_power, p.squad3_power,
         p.squad1_type, p.squad2_type, p.squad3_type
  from public.profiles p
  where p.alliance_id = v_alliance_id
    and p.status = 'active'
  order by p.power desc nulls last, p.display_name
  limit greatest(1, least(coalesce(p_limit,30),200));
end;
$function$;

create or replace function public.alliance_get_weekly_stats_ranking(
  p_actor_profile_id uuid,
  p_from_date date,
  p_to_date date,
  p_limit integer default 30
)
returns table (
  profile_id uuid,
  display_name text,
  vs_points bigint,
  donation_points bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  if p_from_date is null or p_to_date is null or p_from_date > p_to_date
     or p_to_date - p_from_date > 45 then
    raise exception 'Ungültiger Auswertungszeitraum (maximal 46 Tage)';
  end if;

  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';
  if v_alliance_id is null then
    raise exception 'Aktives Spielerprofil gehört nicht zu diesem Konto';
  end if;

  return query
  select p.id, p.display_name,
         sum(s.vs_points)::bigint,
         sum(s.donation_points)::bigint
  from public.nox7_daily_stats s
  join public.profiles p on p.id = s.user_id
  where s.alliance_id = v_alliance_id
    and p.alliance_id = v_alliance_id
    and p.status = 'active'
    and s.status = 'approved'
    and s.report_date between p_from_date and p_to_date
  group by p.id, p.display_name
  order by sum(s.vs_points) desc, sum(s.donation_points) desc, p.display_name
  limit greatest(1, least(coalesce(p_limit,30),200));
end;
$function$;

create or replace function public.alliance_get_power_history(
  p_actor_profile_id uuid,
  p_target_profile_id uuid,
  p_limit integer default 500
)
returns table (power bigint, recorded_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_target_alliance_id uuid;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';
  if v_alliance_id is null then raise exception 'Ungültiges aktives Profil'; end if;

  select p.alliance_id into v_target_alliance_id
  from public.profiles p
  where p.id = p_target_profile_id and p.status = 'active';
  if v_target_alliance_id is null or v_target_alliance_id <> v_alliance_id then
    raise exception 'Zielprofil gehört nicht zur ausgewählten Allianz';
  end if;

  return query
  select h.power, h.recorded_at
  from public.nox7_power_history h
  where h.user_id = p_target_profile_id
    and h.alliance_id = v_alliance_id
  order by h.recorded_at
  limit greatest(1, least(coalesce(p_limit,500),2000));
end;
$function$;

create or replace function public.alliance_get_squad_power_history(
  p_actor_profile_id uuid,
  p_target_profile_id uuid,
  p_squad_number integer,
  p_limit integer default 500
)
returns table (power bigint, recorded_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_target_alliance_id uuid;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  if p_squad_number not between 1 and 3 then raise exception 'Ungültige Squad-Nummer'; end if;
  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';
  if v_alliance_id is null then raise exception 'Ungültiges aktives Profil'; end if;

  select p.alliance_id into v_target_alliance_id
  from public.profiles p
  where p.id = p_target_profile_id and p.status = 'active';
  if v_target_alliance_id is null or v_target_alliance_id <> v_alliance_id then
    raise exception 'Zielprofil gehört nicht zur ausgewählten Allianz';
  end if;

  return query
  select h.power, h.recorded_at
  from public.nox7_squad_power_history h
  where h.user_id = p_target_profile_id
    and h.alliance_id = v_alliance_id
    and h.squad_number = p_squad_number
  order by h.recorded_at
  limit greatest(1, least(coalesce(p_limit,500),2000));
end;
$function$;

create or replace function public.alliance_get_rank_labels(
  p_actor_profile_id uuid
)
returns table (rank_code text, label text)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';
  if v_alliance_id is null then raise exception 'Ungültiges aktives Profil'; end if;

  return query
  select r.rank_code, r.label
  from public.alliance_rank_labels r
  where r.alliance_id = v_alliance_id
  order by r.rank_code;
end;
$function$;

create or replace function public.alliance_set_rank_label(
  p_actor_profile_id uuid,
  p_rank_code text,
  p_label text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_rank text;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  if p_rank_code not in ('R1','R2','R3','R4','R5')
     or p_label is null or char_length(btrim(p_label)) not between 1 and 40 then
    raise exception 'Ungültige Rangbezeichnung';
  end if;

  select p.alliance_id, p.game_rank into v_alliance_id, v_rank
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';
  if v_alliance_id is null then raise exception 'Ungültiges aktives Profil'; end if;
  if not public.nox7_is_primary_admin() and v_rank <> 'R5' then
    raise exception 'Nur R5 darf Rangbezeichnungen ändern';
  end if;

  insert into public.alliance_rank_labels
    (alliance_id, rank_code, label, updated_at, updated_by)
  values (v_alliance_id, p_rank_code, btrim(p_label), now(), p_actor_profile_id)
  on conflict (alliance_id, rank_code)
  do update set label = excluded.label,
                updated_at = now(),
                updated_by = excluded.updated_by;
end;
$function$;

revoke all on function public.alliance_get_power_ranking(uuid,integer) from public, anon;
revoke all on function public.alliance_get_weekly_stats_ranking(uuid,date,date,integer) from public, anon;
revoke all on function public.alliance_get_power_history(uuid,uuid,integer) from public, anon;
revoke all on function public.alliance_get_squad_power_history(uuid,uuid,integer,integer) from public, anon;
revoke all on function public.alliance_get_rank_labels(uuid) from public, anon;
revoke all on function public.alliance_set_rank_label(uuid,text,text) from public, anon;

grant execute on function public.alliance_get_power_ranking(uuid,integer) to authenticated;
grant execute on function public.alliance_get_weekly_stats_ranking(uuid,date,date,integer) to authenticated;
grant execute on function public.alliance_get_power_history(uuid,uuid,integer) to authenticated;
grant execute on function public.alliance_get_squad_power_history(uuid,uuid,integer,integer) to authenticated;
grant execute on function public.alliance_get_rank_labels(uuid) to authenticated;
grant execute on function public.alliance_set_rank_label(uuid,text,text) to authenticated;

commit;

-- Verification:
-- SELECT proname, has_function_privilege('authenticated', oid, 'EXECUTE') AS authenticated_ok,
--        has_function_privilege('anon', oid, 'EXECUTE') AS anon_ok
-- FROM pg_proc JOIN pg_namespace n ON n.oid=pronamespace
-- WHERE n.nspname='public' AND proname LIKE 'alliance_get_%'
--    OR (n.nspname='public' AND proname='alliance_set_rank_label')
-- ORDER BY proname;
