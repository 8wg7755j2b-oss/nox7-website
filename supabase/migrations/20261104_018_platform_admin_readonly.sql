-- Plattform-Admin: read-only foundation for the separate platform console.
-- Access is bound to the fixed primary administrator account, not to an alliance rank.

begin;

create or replace function public.platform_admin_get_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_result jsonb;
begin
  if auth.uid() is distinct from '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid then
    raise exception 'Keine Berechtigung für die Plattformverwaltung';
  end if;

  select jsonb_build_object(
    'alliances', (select count(*) from public.alliances),
    'profiles', (select count(*) from public.profiles),
    'active_profiles', (select count(*) from public.profiles where status = 'active'),
    'accounts', (select count(distinct owner_id) from public.profiles where owner_id is not null)
  )
  into v_result;

  return v_result;
end;
$function$;

create or replace function public.platform_admin_list_alliances()
returns table (
  alliance_id uuid,
  alliance_name text,
  alliance_slug text,
  member_count bigint,
  active_member_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is distinct from '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid then
    raise exception 'Keine Berechtigung für die Plattformverwaltung';
  end if;

  return query
  select a.id, a.name, a.slug,
         count(p.id),
         count(p.id) filter (where p.status = 'active')
  from public.alliances a
  left join public.profiles p on p.alliance_id = a.id
  group by a.id, a.name, a.slug
  order by a.name;
end;
$function$;

create or replace function public.platform_admin_list_profiles()
returns table (
  profile_id uuid,
  alliance_name text,
  display_name text,
  game_rank text,
  profile_role text,
  profile_status text,
  owner_id uuid,
  power bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is distinct from '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid then
    raise exception 'Keine Berechtigung für die Plattformverwaltung';
  end if;

  return query
  select p.id, a.name, p.display_name, p.game_rank, p.role, p.status, p.owner_id, p.power
  from public.profiles p
  left join public.alliances a on a.id = p.alliance_id
  order by a.name nulls last, p.game_rank desc, p.display_name;
end;
$function$;

revoke all on function public.platform_admin_get_overview() from public, anon;
revoke all on function public.platform_admin_list_alliances() from public, anon;
revoke all on function public.platform_admin_list_profiles() from public, anon;
grant execute on function public.platform_admin_get_overview() to authenticated;
grant execute on function public.platform_admin_list_alliances() to authenticated;
grant execute on function public.platform_admin_list_profiles() to authenticated;

commit;

-- Verification (run separately after migration):
-- select public.platform_admin_get_overview();
-- select * from public.platform_admin_list_alliances();
-- select * from public.platform_admin_list_profiles();
