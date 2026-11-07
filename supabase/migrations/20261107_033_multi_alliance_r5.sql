-- Alliance Hub migration 033: allow one account to lead multiple alliances
-- Each alliance still has exactly one active R5. The same account may own
-- separate R5 player profiles in different alliances.
begin;

-- Fail safely if existing data already violates the one-active-R5 rule.
do $preflight$
begin
  if exists (
    select 1
    from public.profiles
    where status = 'active'
      and game_rank = 'R5'
    group by alliance_id
    having count(*) > 1
  ) then
    raise exception 'Migration 033 stopped: at least one alliance has multiple active R5 profiles. Resolve those duplicates before retrying.';
  end if;
end
$preflight$;

-- Enforce one active R5 per alliance, not one R5 per account.
create unique index if not exists profiles_one_active_r5_per_alliance_uidx
  on public.profiles (alliance_id)
  where alliance_id is not null
    and status = 'active'
    and game_rank = 'R5';

-- Creating another alliance is allowed even if the account already leads
-- one or more other alliances. The new alliance receives its own R5 profile.
create or replace function public.create_alliance_for_account(
  p_name text,
  p_slug text,
  p_display_name text
)
returns table(alliance_id uuid, profile_id uuid)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_profile_id uuid := gen_random_uuid();
  v_name text := btrim(coalesce(p_name, ''));
  v_slug text := lower(btrim(coalesce(p_slug, '')));
  v_display_name text := btrim(coalesce(p_display_name, ''));
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if char_length(v_name) not between 2 and 80 then
    raise exception 'Allianzname muss 2 bis 80 Zeichen haben';
  end if;

  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$' then
    raise exception 'Allianz-Kürzel: 3 bis 40 Zeichen, Kleinbuchstaben, Zahlen und Bindestriche';
  end if;

  if char_length(v_display_name) not between 2 and 40 then
    raise exception 'Spielername muss 2 bis 40 Zeichen haben';
  end if;

  insert into public.alliances(name, slug, is_enabled)
  values (v_name, v_slug, true)
  returning id into v_alliance_id;

  insert into public.profiles(
    id, owner_id, alliance_id, display_name, role, game_rank, status
  )
  values (
    v_profile_id, auth.uid(), v_alliance_id, v_display_name,
    'member', 'R5', 'active'
  );

  return query select v_alliance_id, v_profile_id;
end;
$function$;

revoke all on function public.create_alliance_for_account(text, text, text)
  from public, anon;
grant execute on function public.create_alliance_for_account(text, text, text)
  to authenticated;

commit;

-- Verification (run separately after applying):
-- select alliance_id, count(*) as active_r5_count
-- from public.profiles
-- where status = 'active' and game_rank = 'R5'
-- group by alliance_id
-- having count(*) > 1;
-- Expected: zero rows.
