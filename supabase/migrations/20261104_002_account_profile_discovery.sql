-- NOX7 multi-alliance migration: stage 2 (account profile discovery)
-- Additive only: does not alter existing policies, tables, profile IDs or live flows.
-- Exposes only profiles owned by the signed-in account; the fixed platform admin
-- may inspect all alliance profiles for platform administration.

begin;

create or replace function public.get_my_alliance_profiles()
returns table (
  profile_id uuid,
  alliance_id uuid,
  alliance_name text,
  alliance_slug text,
  display_name text,
  game_rank text,
  profile_role text,
  profile_status text,
  is_alliance_admin boolean,
  is_platform_admin boolean
)
language sql
stable
security definer
set search_path = public, auth
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
    (p.game_rank = 'R5' and p.status = 'active'),
    (auth.uid() = '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid)
  from public.profiles p
  left join public.alliances a on a.id = p.alliance_id
  where auth.uid() is not null
    and (
      p.owner_id = auth.uid()
      or auth.uid() = '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid
    )
  order by a.name nulls last, p.display_name;
$function$;

revoke all on function public.get_my_alliance_profiles() from public;
revoke all on function public.get_my_alliance_profiles() from anon;
grant execute on function public.get_my_alliance_profiles() to authenticated;

commit;

-- Verification after applying:
-- select * from public.get_my_alliance_profiles();
