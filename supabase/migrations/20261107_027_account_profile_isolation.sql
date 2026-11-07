-- Restrict "Meine Allianzprofile" to profiles owned by the signed-in account.
-- Platform administrators can still inspect all profiles in the separate platform admin console.
begin;

create or replace function public.get_my_alliance_profiles_v2()
returns table (
  profile_id uuid,
  alliance_id uuid,
  alliance_name text,
  alliance_slug text,
  display_name text,
  game_rank text,
  profile_role text,
  profile_status text,
  join_request_status text,
  join_requested_at timestamptz,
  join_review_note text,
  is_selectable boolean,
  is_alliance_admin boolean,
  is_alliance_manager boolean,
  is_platform_admin boolean
)
language sql
stable
security definer
set search_path = ''
as $function$
  select
    p.id,
    p.alliance_id,
    a.name,
    a.slug,
    p.display_name,
    p.game_rank,
    p.role,
    p.status,
    r.status,
    r.requested_at,
    r.review_note,
    (p.status = 'active'),
    (p.game_rank = 'R5' and p.status = 'active'),
    (
      p.game_rank in ('R4', 'R5')
      and p.status = 'active'
    ),
    public.nox7_is_primary_admin()
  from public.profiles p
  left join public.alliances a
    on a.id = p.alliance_id
  left join public.alliance_join_requests r
    on r.profile_id = p.id
   and r.owner_id = p.owner_id
   and r.alliance_id = p.alliance_id
  where auth.uid() is not null
    and p.owner_id = auth.uid()
  order by a.name nulls last, p.display_name, p.created_at;
$function$;

revoke all on function public.get_my_alliance_profiles_v2() from public, anon;
grant execute on function public.get_my_alliance_profiles_v2() to authenticated;

commit;
