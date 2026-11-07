-- Delete exactly one alliance/player profile while preserving its login account and other profiles.
begin;

-- Invitation codes remain valid after their creator profile is removed.
alter table public.alliance_invitation_codes
  alter column created_by_profile_id drop not null;

alter table public.alliance_invitation_codes
  drop constraint if exists alliance_invitation_codes_created_by_profile_id_fkey;

alter table public.alliance_invitation_codes
  add constraint alliance_invitation_codes_created_by_profile_id_fkey
  foreign key (created_by_profile_id)
  references public.profiles(id)
  on delete set null;

create or replace function public.platform_admin_delete_profile(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_owner_id uuid;
  v_profile_role text;
  v_stats_count bigint := 0;
  v_rows bigint;
begin
  perform public.platform_admin_guard();

  if p_profile_id is null then
    raise exception 'Kein Spielerprofil ausgewählt.';
  end if;

  select p.owner_id, p.role
    into v_owner_id, v_profile_role
  from public.profiles p
  where p.id = p_profile_id
  for update;

  if not found then
    raise exception 'Spielerprofil nicht gefunden oder bereits gelöscht.';
  end if;

  if v_owner_id = '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid
     or v_profile_role = 'admin' then
    raise exception 'Das Plattformadministrator-Profil ist geschützt.';
  end if;

  -- Remove only personal statistics and power history for this one profile.
  delete from public.nox7_daily_stats
   where user_id = p_profile_id;
  get diagnostics v_rows = row_count;
  v_stats_count := v_stats_count + v_rows;

  update public.nox7_daily_stats
     set reviewed_by = null
   where reviewed_by = p_profile_id;

  delete from public.nox7_power_history
   where user_id = p_profile_id;

  delete from public.nox7_squad_power_history
   where user_id = p_profile_id;

  -- Remove references to this profile without affecting shared alliance data.
  update public.alliance_join_requests
     set reviewed_by_profile_id = null
   where reviewed_by_profile_id = p_profile_id;

  update public.alliance_rank_labels
     set updated_by = null
   where updated_by = p_profile_id;

  update public.alliance_site_settings
     set updated_by = null
   where updated_by = p_profile_id;

  update public.profiles
     set archived_by = null
   where archived_by = p_profile_id;

  -- Its own join request is removed by the existing profile_id ON DELETE CASCADE.
  -- The auth.users account and all other profiles belonging to that account remain.
  delete from public.profiles
   where id = p_profile_id;

  if not found then
    raise exception 'Spielerprofil konnte nicht gelöscht werden.';
  end if;

  perform public.platform_admin_log(
    'profile.delete',
    'profile',
    p_profile_id::text,
    jsonb_build_object(
      'owner_id', v_owner_id,
      'deleted_stats', v_stats_count
    )
  );

  return jsonb_build_object(
    'ok', true,
    'owner_id', v_owner_id,
    'deleted_stats', v_stats_count
  );
end;
$function$;

revoke all on function public.platform_admin_delete_profile(uuid) from public, anon;
grant execute on function public.platform_admin_delete_profile(uuid) to authenticated;

commit;
