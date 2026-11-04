-- NOX7 multi-alliance migration: stage 13 (profile, squad, hero and equipment data)
-- Adds profile-aware write RPCs. Existing tables and legacy NOX7 functions remain intact.

begin;

create or replace function public.alliance_update_own_profile_data(
  p_profile_id uuid,
  p_display_name text,
  p_power bigint,
  p_squad1_power bigint,
  p_squad1_type text,
  p_squad2_power bigint,
  p_squad2_type text,
  p_squad3_power bigint,
  p_squad3_type text,
  p_squad_heroes jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_squad jsonb;
  v_hero jsonb;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_display_name is null
     or char_length(btrim(p_display_name)) not between 2 and 40 then
    raise exception 'Spielername muss 2 bis 40 Zeichen haben';
  end if;

  if p_power is not null and p_power < 0
     or p_squad1_power is not null and p_squad1_power < 0
     or p_squad2_power is not null and p_squad2_power < 0
     or p_squad3_power is not null and p_squad3_power < 0 then
    raise exception 'Kampfkraft darf nicht negativ sein';
  end if;

  if (p_squad1_type is not null and p_squad1_type not in ('Panzer','Flugzeug','Rakete'))
     or (p_squad2_type is not null and p_squad2_type not in ('Panzer','Flugzeug','Rakete'))
     or (p_squad3_type is not null and p_squad3_type not in ('Panzer','Flugzeug','Rakete')) then
    raise exception 'Ungültiger Squad-Typ';
  end if;

  if p_squad_heroes is not null then
    if jsonb_typeof(p_squad_heroes) <> 'array'
       or jsonb_array_length(p_squad_heroes) > 3 then
      raise exception 'Helden-Daten müssen aus höchstens drei Squads bestehen';
    end if;
    for v_squad in select value from jsonb_array_elements(p_squad_heroes)
    loop
      if jsonb_typeof(v_squad) <> 'array' or jsonb_array_length(v_squad) > 5 then
        raise exception 'Jedes Squad darf höchstens fünf Helden enthalten';
      end if;
      for v_hero in select value from jsonb_array_elements(v_squad)
      loop
        if jsonb_typeof(v_hero) <> 'object' then
          raise exception 'Ungültiger Heldendatensatz';
        end if;
      end loop;
    end loop;
    if pg_column_size(p_squad_heroes) > 100000 then
      raise exception 'Helden-Daten sind zu umfangreich';
    end if;
  end if;

  update public.profiles
  set display_name = btrim(p_display_name),
      power = p_power,
      squad1_power = p_squad1_power,
      squad1_type = p_squad1_type,
      squad2_power = p_squad2_power,
      squad2_type = p_squad2_type,
      squad3_power = p_squad3_power,
      squad3_type = p_squad3_type,
      squad_heroes = p_squad_heroes
  where id = p_profile_id
    and owner_id = auth.uid()
    and status = 'active';

  if not found then
    raise exception 'Aktives eigenes Spielerprofil nicht gefunden';
  end if;
end;
$function$;

create or replace function public.alliance_update_member_profile_data(
  p_actor_profile_id uuid,
  p_target_profile_id uuid,
  p_display_name text,
  p_power bigint,
  p_squad1_power bigint,
  p_squad1_type text,
  p_squad2_power bigint,
  p_squad2_type text,
  p_squad3_power bigint,
  p_squad3_type text,
  p_squad_heroes jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_squad jsonb;
  v_hero jsonb;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_display_name is null
     or char_length(btrim(p_display_name)) not between 2 and 40 then
    raise exception 'Spielername muss 2 bis 40 Zeichen haben';
  end if;

  if p_power is not null and p_power < 0
     or p_squad1_power is not null and p_squad1_power < 0
     or p_squad2_power is not null and p_squad2_power < 0
     or p_squad3_power is not null and p_squad3_power < 0 then
    raise exception 'Kampfkraft darf nicht negativ sein';
  end if;

  if (p_squad1_type is not null and p_squad1_type not in ('Panzer','Flugzeug','Rakete'))
     or (p_squad2_type is not null and p_squad2_type not in ('Panzer','Flugzeug','Rakete'))
     or (p_squad3_type is not null and p_squad3_type not in ('Panzer','Flugzeug','Rakete')) then
    raise exception 'Ungültiger Squad-Typ';
  end if;

  if p_squad_heroes is not null then
    if jsonb_typeof(p_squad_heroes) <> 'array'
       or jsonb_array_length(p_squad_heroes) > 3 then
      raise exception 'Helden-Daten müssen aus höchstens drei Squads bestehen';
    end if;
    for v_squad in select value from jsonb_array_elements(p_squad_heroes)
    loop
      if jsonb_typeof(v_squad) <> 'array' or jsonb_array_length(v_squad) > 5 then
        raise exception 'Jedes Squad darf höchstens fünf Helden enthalten';
      end if;
      for v_hero in select value from jsonb_array_elements(v_squad)
      loop
        if jsonb_typeof(v_hero) <> 'object' then
          raise exception 'Ungültiger Heldendatensatz';
        end if;
      end loop;
    end loop;
    if pg_column_size(p_squad_heroes) > 100000 then
      raise exception 'Helden-Daten sind zu umfangreich';
    end if;
  end if;

  select actor.alliance_id into v_alliance_id
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

  if v_alliance_id is null and not public.nox7_is_primary_admin() then
    raise exception 'Keine Berechtigung für dieses Mitglied';
  end if;

  if public.nox7_is_primary_admin() then
    select p.alliance_id into v_alliance_id
    from public.profiles p
    where p.id = p_target_profile_id
      and p.status = 'active'
      and p.role <> 'admin';
  end if;

  if v_alliance_id is null then
    raise exception 'Aktives Mitglied nicht gefunden oder geschützt';
  end if;

  update public.profiles
  set display_name = btrim(p_display_name),
      power = p_power,
      squad1_power = p_squad1_power,
      squad1_type = p_squad1_type,
      squad2_power = p_squad2_power,
      squad2_type = p_squad2_type,
      squad3_power = p_squad3_power,
      squad3_type = p_squad3_type,
      squad_heroes = p_squad_heroes
  where id = p_target_profile_id
    and alliance_id = v_alliance_id
    and status = 'active'
    and role <> 'admin';

  if not found then
    raise exception 'Mitglied konnte nicht aktualisiert werden';
  end if;
end;
$function$;

revoke all on function public.alliance_update_own_profile_data(uuid,text,bigint,bigint,text,bigint,text,bigint,text,jsonb) from public, anon;
revoke all on function public.alliance_update_member_profile_data(uuid,uuid,text,bigint,bigint,text,bigint,text,bigint,text,jsonb) from public, anon;

grant execute on function public.alliance_update_own_profile_data(uuid,text,bigint,bigint,text,bigint,text,bigint,text,jsonb) to authenticated;
grant execute on function public.alliance_update_member_profile_data(uuid,uuid,text,bigint,bigint,text,bigint,text,bigint,text,jsonb) to authenticated;

commit;

-- Verification:
-- SELECT p.proname,
--   has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_ok,
--   has_function_privilege('anon',p.oid,'EXECUTE') AS anon_ok
-- FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public' AND p.proname IN (
--   'alliance_update_own_profile_data','alliance_update_member_profile_data'
-- ) ORDER BY p.proname;
