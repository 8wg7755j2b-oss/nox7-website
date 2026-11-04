-- NOX7 multi-alliance migration: stage 1 (additive foundation)
-- Safe first stage: preserves the current profiles.id values and existing
-- auth.users relationship so the live website continues to work unchanged.
-- Do not add tenant RLS or change role constraints until later migration stages.

begin;

create table if not exists public.alliances (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null,
  created_at timestamptz not null default now(),
  constraint alliances_name_check check (char_length(trim(name)) between 2 and 80),
  constraint alliances_slug_check check (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$')
);

create unique index if not exists alliances_slug_uidx
  on public.alliances (slug);

-- Keep the existing NOX7 identity stable on repeated runs.
insert into public.alliances (name, slug)
values ('NOX7', 'nox7')
on conflict (slug) do update
  set name = excluded.name;

alter table public.profiles
  add column if not exists owner_id uuid,
  add column if not exists alliance_id uuid;

do $migration$
declare
  v_nox7_alliance_id uuid;
begin
  select id
    into strict v_nox7_alliance_id
  from public.alliances
  where slug = 'nox7';

  -- Existing accounts keep their current profile UUID. Initially, the
  -- account owner is the same auth user; later stages can add more profiles
  -- for the same owner in other alliances.
  update public.profiles
     set owner_id = coalesce(owner_id, id),
         alliance_id = coalesce(alliance_id, v_nox7_alliance_id)
   where owner_id is null
      or alliance_id is null;

  if not exists (
    select 1
      from pg_constraint
     where conrelid = 'public.profiles'::regclass
       and conname = 'profiles_owner_id_fkey'
  ) then
    alter table public.profiles
      add constraint profiles_owner_id_fkey
      foreign key (owner_id) references auth.users(id);
  end if;

  if not exists (
    select 1
      from pg_constraint
     where conrelid = 'public.profiles'::regclass
       and conname = 'profiles_alliance_id_fkey'
  ) then
    alter table public.profiles
      add constraint profiles_alliance_id_fkey
      foreign key (alliance_id) references public.alliances(id);
  end if;
end
$migration$;

-- One account may have at most one player profile per alliance.
-- NULL values remain permitted temporarily for compatibility with the
-- currently deployed registration flow.
create unique index if not exists profiles_owner_alliance_uidx
  on public.profiles (owner_id, alliance_id)
  where owner_id is not null and alliance_id is not null;

create index if not exists profiles_alliance_id_idx
  on public.profiles (alliance_id);

-- The alliance catalog is intentionally not directly accessible from browser
-- clients in this stage. Later stages will expose scoped, authorized RPCs.
alter table public.alliances enable row level security;
revoke all on table public.alliances from anon, authenticated;

commit;

-- Verification (run separately after the migration):
-- select a.id, a.name, a.slug, count(p.id) as profiles
-- from public.alliances a
-- left join public.profiles p on p.alliance_id = a.id
-- group by a.id, a.name, a.slug
-- order by a.slug;
--
-- select count(*) as profiles_missing_owner_or_alliance
-- from public.profiles
-- where owner_id is null or alliance_id is null;
