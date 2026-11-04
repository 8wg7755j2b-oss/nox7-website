-- NOX7 multi-alliance migration: stage 6 (alliance authorization helpers)
-- Introduces reusable, tenant-aware authorization checks.
-- This stage intentionally does NOT change existing RLS policies, grants,
-- signup flows, or legacy NOX7 RPCs. The live website remains compatible.
--
-- Authorization model:
-- * A player profile belongs to one auth account (profiles.owner_id).
-- * Alliance membership is determined by an active profile in that alliance.
-- * R4 may manage ordinary alliance operations; R5 may manage R4/R1-R3
--   and alliance settings. Platform admin bypasses alliance boundaries.
-- * Rank checks use profiles.game_rank, not the legacy global role column.
--   This keeps alliance leadership separate from platform administration.

begin;

-- An account may read/use an alliance only if it owns an active profile there.
-- The fixed platform administrator is allowed to inspect every alliance.
create or replace function public.nox7_can_access_alliance(
  p_alliance_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    auth.uid() is not null
    and p_alliance_id is not null
    and (
      public.nox7_is_primary_admin()
      or exists (
        select 1
        from public.profiles p
        where p.owner_id = auth.uid()
          and p.alliance_id = p_alliance_id
          and p.status = 'active'
      )
    );
$function$;

-- Minimum rank is deliberately restricted to R4 or R5.
-- R4-level management accepts R4 and R5; R5-level management accepts R5 only.
create or replace function public.nox7_can_manage_alliance(
  p_alliance_id uuid,
  p_min_rank text default 'R4'
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    auth.uid() is not null
    and p_alliance_id is not null
    and p_min_rank in ('R4', 'R5')
    and (
      public.nox7_is_primary_admin()
      or exists (
        select 1
        from public.profiles p
        where p.owner_id = auth.uid()
          and p.alliance_id = p_alliance_id
          and p.status = 'active'
          and (
            p.game_rank = 'R5'
            or (p_min_rank = 'R4' and p.game_rank = 'R4')
          )
      )
    );
$function$;

-- Check a target profile in its own alliance. The caller must own an active
-- R4/R5 profile in that same alliance, unless they are platform admin.
-- This prevents a manager from passing a profile UUID from another alliance.
create or replace function public.nox7_can_manage_profile(
  p_target_profile_id uuid,
  p_min_rank text default 'R4'
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    auth.uid() is not null
    and p_target_profile_id is not null
    and p_min_rank in ('R4', 'R5')
    and (
      public.nox7_is_primary_admin()
      or exists (
        select 1
        from public.profiles target
        join public.profiles actor
          on actor.alliance_id = target.alliance_id
        where target.id = p_target_profile_id
          and target.status = 'active'
          and actor.owner_id = auth.uid()
          and actor.status = 'active'
          and (
            actor.game_rank = 'R5'
            or (p_min_rank = 'R4' and actor.game_rank = 'R4')
          )
      )
    );
$function$;

-- Validate that a selected player profile belongs to the signed-in account.
-- Platform admin may select any active profile. This helper is intended for
-- later RPCs that receive an explicit selected profile UUID from the client.
create or replace function public.nox7_owns_active_profile(
  p_profile_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select
    auth.uid() is not null
    and p_profile_id is not null
    and (
      public.nox7_is_primary_admin()
      or exists (
        select 1
        from public.profiles p
        where p.id = p_profile_id
          and p.owner_id = auth.uid()
          and p.status = 'active'
      )
    );
$function$;

-- Do not expose these authorization helpers to anonymous callers.
revoke all on function public.nox7_can_access_alliance(uuid) from public, anon;
revoke all on function public.nox7_can_manage_alliance(uuid, text) from public, anon;
revoke all on function public.nox7_can_manage_profile(uuid, text) from public, anon;
revoke all on function public.nox7_owns_active_profile(uuid) from public, anon;

grant execute on function public.nox7_can_access_alliance(uuid) to authenticated;
grant execute on function public.nox7_can_manage_alliance(uuid, text) to authenticated;
grant execute on function public.nox7_can_manage_profile(uuid, text) to authenticated;
grant execute on function public.nox7_owns_active_profile(uuid) to authenticated;

commit;

-- Verification (run separately after applying):
-- select
--   to_regprocedure('public.nox7_can_access_alliance(uuid)') is not null
--     as can_access_alliance_exists,
--   to_regprocedure('public.nox7_can_manage_alliance(uuid,text)') is not null
--     as can_manage_alliance_exists,
--   to_regprocedure('public.nox7_can_manage_profile(uuid,text)') is not null
--     as can_manage_profile_exists,
--   to_regprocedure('public.nox7_owns_active_profile(uuid)') is not null
--     as owns_active_profile_exists;
--
-- These helpers require an authenticated JWT to return true for ordinary
-- members. SQL Editor tests without auth.uid() will correctly return false.
