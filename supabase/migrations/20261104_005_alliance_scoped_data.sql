-- NOX7 multi-alliance migration: stage 5 (alliance-scoped data foundations)
-- Additive and compatibility-focused:
-- * Existing NOX7 rows are retained and assigned to the NOX7 alliance.
-- * Legacy NOX7 rank-label and site-setting tables remain unchanged so the
--   current website continues to work; new per-alliance tables are introduced.
-- * Existing daily-stat submissions without an alliance_id are resolved from
--   their player profile by a trigger.
-- * Existing post inserts that omit alliance_id continue to default to NOX7.
-- Do not enable the new tables in the frontend until matching scoped RPCs
-- and tenant-aware RLS policies have been implemented.

begin;

do $preflight$
declare
  v_nox7_alliance_id uuid;
begin
  select id into strict v_nox7_alliance_id
  from public.alliances
  where slug = 'nox7';

  if exists (
    select 1
    from public.nox7_daily_stats s
    left join public.profiles p on p.id = s.user_id
    where p.id is null
  ) then
    raise exception 'Migration 005 stopped: daily stats contain a user_id without a matching profile';
  end if;

  if exists (
    select 1
    from public.nox7_power_history h
    left join public.profiles p on p.id = h.user_id
    where p.id is null
  ) then
    raise exception 'Migration 005 stopped: power history contains a user_id without a matching profile';
  end if;

  if exists (
    select 1
    from public.nox7_squad_power_history h
    left join public.profiles p on p.id = h.user_id
    where p.id is null
  ) then
    raise exception 'Migration 005 stopped: squad power history contains a user_id without a matching profile';
  end if;
end
$preflight$;

-- 1. Add alliance ownership to historical and operational data tables.
alter table public.nox7_daily_stats
  add column if not exists alliance_id uuid;

alter table public.nox7_power_history
  add column if not exists alliance_id uuid;

alter table public.nox7_squad_power_history
  add column if not exists alliance_id uuid;

alter table public.posts
  add column if not exists alliance_id uuid;

-- Backfill from the owning player profile. This preserves every existing row
-- and assigns all existing NOX7 data to its current alliance.
update public.nox7_daily_stats s
set alliance_id = p.alliance_id
from public.profiles p
where p.id = s.user_id
  and s.alliance_id is distinct from p.alliance_id;

update public.nox7_power_history h
set alliance_id = p.alliance_id
from public.profiles p
where p.id = h.user_id
  and h.alliance_id is distinct from p.alliance_id;

update public.nox7_squad_power_history h
set alliance_id = p.alliance_id
from public.profiles p
where p.id = h.user_id
  and h.alliance_id is distinct from p.alliance_id;

-- All posts that existed before multi-alliance support belong to NOX7.
do $backfill_posts$
declare
  v_nox7_alliance_id uuid;
begin
  select id into strict v_nox7_alliance_id
  from public.alliances
  where slug = 'nox7';

  update public.posts
  set alliance_id = v_nox7_alliance_id
  where alliance_id is null;
end
$backfill_posts$;

-- Fail safely rather than silently assigning an unknown row to an alliance.
do $null_check$
begin
  if exists (select 1 from public.nox7_daily_stats where alliance_id is null) then
    raise exception 'Migration 005 stopped: a daily-stat row could not be assigned to an alliance';
  end if;
  if exists (select 1 from public.nox7_power_history where alliance_id is null) then
    raise exception 'Migration 005 stopped: a power-history row could not be assigned to an alliance';
  end if;
  if exists (select 1 from public.nox7_squad_power_history where alliance_id is null) then
    raise exception 'Migration 005 stopped: a squad-history row could not be assigned to an alliance';
  end if;
  if exists (select 1 from public.posts where alliance_id is null) then
    raise exception 'Migration 005 stopped: a post could not be assigned to an alliance';
  end if;
end
$null_check$;

alter table public.nox7_daily_stats
  alter column alliance_id set not null;

alter table public.nox7_power_history
  alter column alliance_id set not null;

alter table public.nox7_squad_power_history
  alter column alliance_id set not null;

alter table public.posts
  alter column alliance_id set not null;

-- Prevent deleting an alliance while it still owns historical/operational data.
do $foreign_keys$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.nox7_daily_stats'::regclass and conname = 'nox7_daily_stats_alliance_id_fkey') then
    alter table public.nox7_daily_stats
      add constraint nox7_daily_stats_alliance_id_fkey
      foreign key (alliance_id) references public.alliances(id) on delete restrict;
  end if;

  if not exists (select 1 from pg_constraint where conrelid = 'public.nox7_power_history'::regclass and conname = 'nox7_power_history_alliance_id_fkey') then
    alter table public.nox7_power_history
      add constraint nox7_power_history_alliance_id_fkey
      foreign key (alliance_id) references public.alliances(id) on delete restrict;
  end if;

  if not exists (select 1 from pg_constraint where conrelid = 'public.nox7_squad_power_history'::regclass and conname = 'nox7_squad_power_history_alliance_id_fkey') then
    alter table public.nox7_squad_power_history
      add constraint nox7_squad_power_history_alliance_id_fkey
      foreign key (alliance_id) references public.alliances(id) on delete restrict;
  end if;

  if not exists (select 1 from pg_constraint where conrelid = 'public.posts'::regclass and conname = 'posts_alliance_id_fkey') then
    alter table public.posts
      add constraint posts_alliance_id_fkey
      foreign key (alliance_id) references public.alliances(id) on delete restrict;
  end if;
end
$foreign_keys$;

-- Legacy post creation remains compatible: omitted alliance_id means NOX7.
do $post_default$
declare
  v_nox7_alliance_id uuid;
begin
  select id into strict v_nox7_alliance_id
  from public.alliances
  where slug = 'nox7';

  execute format(
    'alter table public.posts alter column alliance_id set default %L::uuid',
    v_nox7_alliance_id
  );
end
$post_default$;

-- 2. Resolve alliance_id for legacy daily-stat RPCs that still insert only
-- user_id. New multi-alliance RPCs should pass the alliance_id explicitly;
-- the trigger validates it against the selected profile and prevents spoofing.
create or replace function public.set_nox7_daily_stats_alliance_id()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_profile_alliance_id uuid;
begin
  select p.alliance_id
    into v_profile_alliance_id
  from public.profiles p
  where p.id = new.user_id;

  if v_profile_alliance_id is null then
    raise exception 'Spielerprofil oder Allianz nicht gefunden';
  end if;

  if new.alliance_id is not null
     and new.alliance_id <> v_profile_alliance_id then
    raise exception 'Die Meldung gehört nicht zur Allianz des Spielerprofils';
  end if;

  new.alliance_id := v_profile_alliance_id;
  return new;
end;
$function$;

drop trigger if exists trg_set_nox7_daily_stats_alliance_id
  on public.nox7_daily_stats;

create trigger trg_set_nox7_daily_stats_alliance_id
before insert or update of user_id, alliance_id
on public.nox7_daily_stats
for each row
execute function public.set_nox7_daily_stats_alliance_id();

-- 3. Update history capture functions to persist the profile's alliance_id.
create or replace function public.capture_nox7_power_history()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.power is not null and (
    tg_op = 'INSERT' or old.power is distinct from new.power
  ) then
    insert into public.nox7_power_history(user_id, alliance_id, power, recorded_at)
    values (new.id, new.alliance_id, new.power, now());
  end if;
  return new;
end;
$function$;

create or replace function public.capture_nox7_squad_power_history()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.squad1_power is not null and (
    tg_op = 'INSERT' or old.squad1_power is distinct from new.squad1_power
  ) then
    insert into public.nox7_squad_power_history
      (user_id, alliance_id, squad_number, power)
    values (new.id, new.alliance_id, 1, new.squad1_power);
  end if;

  if new.squad2_power is not null and (
    tg_op = 'INSERT' or old.squad2_power is distinct from new.squad2_power
  ) then
    insert into public.nox7_squad_power_history
      (user_id, alliance_id, squad_number, power)
    values (new.id, new.alliance_id, 2, new.squad2_power);
  end if;

  if new.squad3_power is not null and (
    tg_op = 'INSERT'
    or old.squad3_power is distinct from new.squad3_power
  ) then
    insert into public.nox7_squad_power_history
      (user_id, alliance_id, squad_number, power)
    values (new.id, new.alliance_id, 3, new.squad3_power);
  end if;

  return new;
end;
$function$;

-- 4. New per-alliance rank labels and settings. Keep the old NOX7 tables
-- untouched because the currently deployed frontend still reads/writes them.
create table if not exists public.alliance_rank_labels (
  alliance_id uuid not null references public.alliances(id) on delete cascade,
  rank_code text not null,
  label text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint alliance_rank_labels_pkey primary key (alliance_id, rank_code)
);

create table if not exists public.alliance_site_settings (
  alliance_id uuid not null references public.alliances(id) on delete cascade,
  setting_key text not null,
  setting_value boolean not null,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint alliance_site_settings_pkey primary key (alliance_id, setting_key)
);

-- Copy current NOX7 values as the initial values for the NOX7 tenant.
do $seed_alliance_tables$
declare
  v_nox7_alliance_id uuid;
begin
  select id into strict v_nox7_alliance_id
  from public.alliances
  where slug = 'nox7';

  insert into public.alliance_rank_labels
    (alliance_id, rank_code, label, updated_at, updated_by)
  select v_nox7_alliance_id, rank_code, label, updated_at, updated_by
  from public.nox7_rank_labels
  on conflict (alliance_id, rank_code) do nothing;

  insert into public.alliance_site_settings
    (alliance_id, setting_key, setting_value)
  select v_nox7_alliance_id, setting_key, setting_value
  from public.nox7_site_settings
  on conflict (alliance_id, setting_key) do nothing;
end
$seed_alliance_tables$;

-- 5. Indexes for tenant-scoped reads. Existing primary/unique keys remain intact.
create index if not exists nox7_daily_stats_alliance_date_idx
  on public.nox7_daily_stats(alliance_id, report_date);

create index if not exists nox7_power_history_alliance_user_time_idx
  on public.nox7_power_history(alliance_id, user_id, recorded_at);

create index if not exists nox7_squad_history_alliance_user_time_idx
  on public.nox7_squad_power_history(alliance_id, user_id, recorded_at);

create index if not exists posts_alliance_created_at_idx
  on public.posts(alliance_id, created_at desc);

create index if not exists alliance_rank_labels_alliance_idx
  on public.alliance_rank_labels(alliance_id);

create index if not exists alliance_site_settings_alliance_idx
  on public.alliance_site_settings(alliance_id);

-- Browser access remains closed until scoped RPCs and policies are introduced.
alter table public.alliance_rank_labels enable row level security;
alter table public.alliance_site_settings enable row level security;

revoke all on table public.alliance_rank_labels from anon, authenticated;
revoke all on table public.alliance_site_settings from anon, authenticated;

commit;

-- Verification (run separately after applying):
-- select 'daily_stats' as table_name, count(*) as total_rows,
--        count(alliance_id) as rows_with_alliance
-- from public.nox7_daily_stats
-- union all
-- select 'power_history', count(*), count(alliance_id)
-- from public.nox7_power_history
-- union all
-- select 'squad_power_history', count(*), count(alliance_id)
-- from public.nox7_squad_power_history
-- union all
-- select 'posts', count(*), count(alliance_id)
-- from public.posts;
--
-- select a.name, count(distinct rl.rank_code) as rank_labels
-- from public.alliances a
-- left join public.alliance_rank_labels rl on rl.alliance_id = a.id
-- group by a.name;
--
-- select a.name, count(distinct s.setting_key) as settings
-- from public.alliances a
-- left join public.alliance_site_settings s on s.alliance_id = a.id
-- group by a.name;
