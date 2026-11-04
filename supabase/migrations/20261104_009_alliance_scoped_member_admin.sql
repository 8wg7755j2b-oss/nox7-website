-- NOX7 multi-alliance migration: stage 9 (alliance-scoped member administration)
-- New RPCs take an explicit actor profile UUID and target profile UUID.
-- Legacy NOX7 RPCs remain untouched for compatibility with the current website.

begin;

-- Update a member's display name and power only within the actor's alliance.
create or replace function public.alliance_update_member_details(
  p_actor_profile_id uuid,
  p_target_profile_id uuid,
  p_display_name text,
  p_power bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_display_name is null
     or char_length(btrim(p_display_name)) not between 2 and 40 then
    raise exception 'Spielername muss 2 bis 40 Zeichen haben';
  end if;

  if p_power is not null and p_power < 0 then
    raise exception 'Ungültige Kampfkraft';
  end if;

  if public.nox7_is_primary_admin() then
    select p.alliance_id into v_alliance_id
    from public.profiles p
    where p.id = p_target_profile_id and p.status = 'active';
  else
    select actor.alliance_id into v_alliance_id
    from public.profiles actor
    where actor.id = p_actor_profile_id
      and actor.owner_id = auth.uid()
      and actor.status = 'active'
      and actor.game_rank in ('R4','R5')
      and exists (
        select 1 from public.profiles target
        where target.id = p_target_profile_id
          and target.alliance_id = actor.alliance_id
          and target.status = 'active'
          and target.role <> 'admin'
      );
  end if;

  if v_alliance_id is null then
    raise exception 'Keine Berechtigung für dieses Mitglied oder diese Allianz';
  end if;

  update public.profiles
  set display_name = btrim(p_display_name),
      power = p_power
  where id = p_target_profile_id
    and alliance_id = v_alliance_id
    and status = 'active'
    and role <> 'admin';

  if not found then
    raise exception 'Aktives Mitglied nicht gefunden oder geschützt';
  end if;
end;
$function$;

-- Rank changes are bounded by the actor's rank and always scoped to one alliance.
create or replace function public.alliance_set_member_rank(
  p_actor_profile_id uuid,
  p_target_profile_id uuid,
  p_game_rank text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_actor_rank text;
  v_target_rank text;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_game_rank not in ('R1','R2','R3','R4','R5') then
    raise exception 'Ungültiger Rang';
  end if;

  if public.nox7_is_primary_admin() then
    select p.alliance_id, p.game_rank
      into v_alliance_id, v_target_rank
    from public.profiles p
    where p.id = p_target_profile_id and p.status = 'active';
    v_actor_rank := 'ADMIN';
  else
    select actor.alliance_id, actor.game_rank, target.game_rank
      into v_alliance_id, v_actor_rank, v_target_rank
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

  if v_target_rank = 'R5' then
    raise exception 'Der R5-Rang kann nur über die R5-Übergabe geändert werden';
  end if;

  if v_actor_rank = 'R4' and p_game_rank not in ('R1','R2','R3') then
    raise exception 'R4 darf nur R1 bis R3 vergeben';
  end if;

  if v_actor_rank = 'R5' and p_game_rank = 'R5' then
    raise exception 'R5 muss über die R5-Übergabe vergeben werden';
  end if;

  if p_game_rank = 'R5' and not public.nox7_is_primary_admin() then
    raise exception 'Nur die R5-Übergabe darf den R5-Rang vergeben';
  end if;

  update public.profiles
  set game_rank = p_game_rank
  where id = p_target_profile_id
    and alliance_id = v_alliance_id
    and status = 'active'
    and role <> 'admin';

  if not found then
    raise exception 'Aktives Mitglied nicht gefunden oder geschützt';
  end if;
end;
$function$;

-- Archive a member within the actor's alliance. A current R5 must be handed
-- over first; the fixed platform administrator is never archivable.
create or replace function public.alliance_archive_member(
  p_actor_profile_id uuid,
  p_target_profile_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_actor_rank text;
  v_target_rank text;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_reason not in ('left','kicked','transferred') then
    raise exception 'Ungültiger Archivgrund';
  end if;

  if public.nox7_is_primary_admin() then
    select p.alliance_id, p.game_rank
      into v_alliance_id, v_target_rank
    from public.profiles p
    where p.id = p_target_profile_id
      and p.status = 'active'
      and p.role <> 'admin';
    v_actor_rank := 'ADMIN';
  else
    select actor.alliance_id, actor.game_rank, target.game_rank
      into v_alliance_id, v_actor_rank, v_target_rank
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

  if v_target_rank = 'R5' then
    raise exception 'Der R5 muss zuerst die Allianzführung übergeben';
  end if;

  if v_actor_rank = 'R4' and v_target_rank = 'R4' then
    raise exception 'R4 darf keine anderen R4-Mitglieder archivieren';
  end if;

  update public.profiles
  set status = p_reason,
      archive_reason = p_reason,
      archived_at = now(),
      archived_by = p_actor_profile_id
  where id = p_target_profile_id
    and alliance_id = v_alliance_id
    and status = 'active'
    and role <> 'admin';

  if not found then
    raise exception 'Mitglied nicht gefunden oder geschützt';
  end if;
end;
$function$;

-- Reactivate an archived former member, never a pending/rejected join request.
create or replace function public.alliance_reactivate_member(
  p_actor_profile_id uuid,
  p_target_profile_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_actor_rank text;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if public.nox7_is_primary_admin() then
    select p.alliance_id into v_alliance_id
    from public.profiles p
    where p.id = p_target_profile_id
      and p.status in ('left','kicked','transferred')
      and p.role <> 'admin';
    v_actor_rank := 'ADMIN';
  else
    select actor.alliance_id, actor.game_rank
      into v_alliance_id, v_actor_rank
    from public.profiles actor
    join public.profiles target
      on target.alliance_id = actor.alliance_id
    where actor.id = p_actor_profile_id
      and actor.owner_id = auth.uid()
      and actor.status = 'active'
      and actor.game_rank in ('R4','R5')
      and target.id = p_target_profile_id
      and target.status in ('left','kicked','transferred')
      and target.role <> 'admin';
  end if;

  if v_alliance_id is null then
    raise exception 'Keine Berechtigung oder kein reaktivierbares Mitglied gefunden';
  end if;

  update public.profiles
  set status = 'active',
      archive_reason = null,
      archived_at = null,
      archived_by = null
  where id = p_target_profile_id
    and alliance_id = v_alliance_id
    and status in ('left','kicked','transferred')
    and role <> 'admin';

  if not found then
    raise exception 'Mitglied konnte nicht reaktiviert werden';
  end if;
end;
$function$;

-- Transfer R5 only inside the selected alliance; the partial unique index
-- guarantees no second active R5 can be created.
create or replace function public.alliance_transfer_r5(
  p_actor_profile_id uuid,
  p_new_r5_profile_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_old_r5_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if public.nox7_is_primary_admin() then
    select p.alliance_id into v_alliance_id
    from public.profiles p
    where p.id = p_new_r5_profile_id
      and p.status = 'active'
      and p.role <> 'admin';
  else
    select actor.alliance_id into v_alliance_id
    from public.profiles actor
    join public.profiles target
      on target.alliance_id = actor.alliance_id
    where actor.id = p_actor_profile_id
      and actor.owner_id = auth.uid()
      and actor.status = 'active'
      and actor.game_rank = 'R5'
      and target.id = p_new_r5_profile_id
      and target.status = 'active'
      and target.role <> 'admin';
  end if;

  if v_alliance_id is null then
    raise exception 'Nur der R5 darf an ein aktives Mitglied derselben Allianz übergeben';
  end if;

  select p.id into v_old_r5_id
  from public.profiles p
  where p.alliance_id = v_alliance_id
    and p.game_rank = 'R5'
    and p.status = 'active'
  for update;

  if v_old_r5_id is null then
    raise exception 'Aktueller R5 wurde nicht gefunden';
  end if;

  if v_old_r5_id = p_new_r5_profile_id then
    raise exception 'Dieses Mitglied ist bereits R5';
  end if;

  update public.profiles
  set game_rank = 'R1'
  where id = v_old_r5_id and alliance_id = v_alliance_id;

  update public.profiles
  set game_rank = 'R5'
  where id = p_new_r5_profile_id
    and alliance_id = v_alliance_id
    and status = 'active';

  if not found then
    raise exception 'Neuer R5 konnte nicht gesetzt werden';
  end if;
end;
$function$;

revoke all on function public.alliance_update_member_details(uuid,uuid,text,bigint) from public, anon;
revoke all on function public.alliance_set_member_rank(uuid,uuid,text) from public, anon;
revoke all on function public.alliance_archive_member(uuid,uuid,text) from public, anon;
revoke all on function public.alliance_reactivate_member(uuid,uuid) from public, anon;
revoke all on function public.alliance_transfer_r5(uuid,uuid) from public, anon;

grant execute on function public.alliance_update_member_details(uuid,uuid,text,bigint) to authenticated;
grant execute on function public.alliance_set_member_rank(uuid,uuid,text) to authenticated;
grant execute on function public.alliance_archive_member(uuid,uuid,text) to authenticated;
grant execute on function public.alliance_reactivate_member(uuid,uuid) to authenticated;
grant execute on function public.alliance_transfer_r5(uuid,uuid) to authenticated;

commit;

-- Verification:
-- select
--   to_regprocedure('public.alliance_update_member_details(uuid,uuid,text,bigint)') is not null as update_details,
--   to_regprocedure('public.alliance_set_member_rank(uuid,uuid,text)') is not null as set_rank,
--   to_regprocedure('public.alliance_archive_member(uuid,uuid,text)') is not null as archive_member,
--   to_regprocedure('public.alliance_reactivate_member(uuid,uuid)') is not null as reactivate_member,
--   to_regprocedure('public.alliance_transfer_r5(uuid,uuid)') is not null as transfer_r5;
--
-- Test through authenticated application sessions before wiring these RPCs into
-- the frontend. Legacy NOX7 RPCs are intentionally retained unchanged.
