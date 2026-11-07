-- Permanently delete a platform account and all account-owned game data.
-- The fixed platform administrator account is protected from deletion.
begin;

create or replace function public.platform_admin_delete_account(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_profile_ids uuid[];
  v_invitation_ids uuid[];
  v_profile_count bigint;
  v_stats_count bigint := 0;
  v_rows bigint;
begin
  perform public.platform_admin_guard();

  if p_user_id is null or p_user_id = auth.uid()
     or p_user_id = '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid then
    raise exception 'Das Plattformadministrator-Konto ist geschützt und kann nicht gelöscht werden.';
  end if;

  select u.email into v_email
  from auth.users u
  where u.id = p_user_id
  for update;

  if not found then
    raise exception 'Das Konto wurde nicht gefunden oder bereits gelöscht.';
  end if;

  select coalesce(array_agg(p.id), array[]::uuid[])
    into v_profile_ids
  from public.profiles p
  where p.owner_id = p_user_id;

  v_profile_count := cardinality(v_profile_ids);

  -- Preserve other members' requests, but remove references to this member
  -- as reviewer and detach requests that used invitation codes they created.
  update public.alliance_join_requests
     set reviewed_by_profile_id = null
   where reviewed_by_profile_id = any(v_profile_ids);

  select coalesce(array_agg(c.id), array[]::uuid[])
    into v_invitation_ids
  from public.alliance_invitation_codes c
  where c.created_by_profile_id = any(v_profile_ids);

  if cardinality(v_invitation_ids) > 0 then
    update public.alliance_join_requests
       set invitation_id = null
     where invitation_id = any(v_invitation_ids);
    delete from public.alliance_invitation_codes
     where id = any(v_invitation_ids);
  end if;

  -- Remove the account's own submissions and historical power records.
  delete from public.nox7_daily_stats
   where user_id = any(v_profile_ids);
  get diagnostics v_rows = row_count;
  v_stats_count := v_stats_count + v_rows;

  -- Remove stale reviewer references from other members' submissions.
  update public.nox7_daily_stats
     set reviewed_by = null
   where reviewed_by = any(v_profile_ids);

  delete from public.nox7_power_history
   where user_id = any(v_profile_ids);
  delete from public.nox7_squad_power_history
   where user_id = any(v_profile_ids);

  -- These are shared alliance settings; keep the settings but remove the
  -- deleted member's attribution.
  update public.alliance_rank_labels
     set updated_by = null
   where updated_by = any(v_profile_ids);
  update public.alliance_site_settings
     set updated_by = null
   where updated_by = any(v_profile_ids);

  -- Clear archive attribution on profiles that remain in the system.
  update public.profiles
     set archived_by = null
   where archived_by = any(v_profile_ids);

  -- auth.users -> profiles and auth.users -> join_requests are configured
  -- with ON DELETE CASCADE, removing every profile and its join requests.
  delete from auth.users where id = p_user_id;

  if not found then
    raise exception 'Das Konto konnte nicht endgültig gelöscht werden.';
  end if;

  -- Audit only the account UUID and row counts; no email or username is kept.
  perform public.platform_admin_log(
    'account.delete',
    'account',
    p_user_id::text,
    jsonb_build_object(
      'profile_count', v_profile_count,
      'deleted_stats', v_stats_count
    )
  );

  return jsonb_build_object(
    'ok', true,
    'deleted_profiles', v_profile_count,
    'deleted_stats', v_stats_count
  );
end;
$function$;

revoke all on function public.platform_admin_delete_account(uuid) from public, anon;
grant execute on function public.platform_admin_delete_account(uuid) to authenticated;

commit;
