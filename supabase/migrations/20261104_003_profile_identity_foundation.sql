-- NOX7 multi-alliance migration: stage 3 (profile identity foundation)
-- IMPORTANT:
--   * Run only after stages 001 and 002 have been applied and verified.
--   * This migration does not create additional alliance profiles yet.
--   * Existing profile UUIDs and all dependent history/statistics rows are preserved.
--   * The legacy signup flow remains NOX7-only until the alliance invitation stage.

begin;

-- Fail safely rather than silently migrating an incomplete foundation.
do $migration$
begin
  if exists (
    select 1 from public.profiles
    where owner_id is null or alliance_id is null
  ) then
    raise exception
      'Migration stopped: profiles still contain NULL owner_id or alliance_id values.';
  end if;

  if exists (
    select 1
    from public.profiles
    group by owner_id, alliance_id
    having count(*) > 1
  ) then
    raise exception
      'Migration stopped: an account has more than one profile in the same alliance.';
  end if;

  if exists (
    select 1
    from public.profiles
    where status = 'active' and game_rank = 'R5'
    group by alliance_id
    having count(*) > 1
  ) then
    raise exception
      'Migration stopped: an alliance has more than one active R5 profile.';
  end if;
end
$migration$;

-- Every player profile must belong to one account and one alliance.
-- The preflight above guarantees these constraints can be applied safely.
alter table public.profiles
  alter column owner_id set not null,
  alter column alliance_id set not null;

-- Preserve the old account-deletion behavior: deleting an auth account removes
-- its owned profiles, and existing profile-history FKs cascade from those IDs.
alter table public.profiles
  drop constraint if exists profiles_owner_id_fkey;
alter table public.profiles
  add constraint profiles_owner_id_fkey
  foreign key (owner_id) references auth.users(id) on delete cascade;

-- A player profile is no longer required to share its UUID with auth.users.
-- owner_id remains the account relationship. Existing profile IDs are untouched.
alter table public.profiles
  drop constraint if exists profiles_id_fkey;

-- Player names only need to be unique inside one alliance.
drop index if exists public.profiles_display_name_unique;
create unique index profiles_alliance_display_name_uidx
  on public.profiles (alliance_id, lower(btrim(display_name)))
  where alliance_id is not null
    and display_name is not null
    and btrim(display_name) <> '';

-- Each alliance may have one active R5, independently of other alliances.
drop index if exists public.profiles_only_one_active_r5;
create unique index profiles_one_active_r5_per_alliance_uidx
  on public.profiles (alliance_id)
  where alliance_id is not null
    and game_rank = 'R5'
    and status = 'active';

-- Keep the existing signup path functional during the staged migration.
-- Until alliance-specific invitation handling is deployed, new signups still
-- join NOX7, but their profile is correctly linked to the owning auth account.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  requested_name text;
  v_nox7_alliance_id uuid;
begin
  requested_name := nullif(
    btrim(new.raw_user_meta_data->>'display_name'),
    ''
  );

  if requested_name is null
     or char_length(requested_name) < 2
     or char_length(requested_name) > 40 then
    raise exception 'Bitte einen gültigen Spielernamen angeben.';
  end if;

  select a.id
    into strict v_nox7_alliance_id
  from public.alliances a
  where a.slug = 'nox7';

  insert into public.profiles (
    id,
    owner_id,
    alliance_id,
    display_name,
    role,
    game_rank
  )
  values (
    new.id,
    new.id,
    v_nox7_alliance_id,
    requested_name,
    'member',
    'R1'
  );

  return new;
end;
$function$;

commit;

-- Verification (run separately after applying):
-- 1) No profile has lost its account or alliance association:
-- select count(*) as incomplete_profiles
-- from public.profiles
-- where owner_id is null or alliance_id is null;
--
-- 2) Existing profile UUIDs remain valid and mapped:
-- select p.id, p.owner_id, a.name as alliance, p.display_name, p.game_rank, p.status
-- from public.profiles p
-- left join public.alliances a on a.id = p.alliance_id
-- order by a.name, p.display_name;
--
-- 3) The one-active-R5 index is now alliance-scoped:
-- select indexname, indexdef
-- from pg_indexes
-- where schemaname = 'public'
--   and tablename = 'profiles'
--   and indexname in (
--     'profiles_alliance_display_name_uidx',
--     'profiles_one_active_r5_per_alliance_uidx'
--   );
