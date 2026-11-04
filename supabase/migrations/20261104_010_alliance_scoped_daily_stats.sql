-- NOX7 multi-alliance migration: stage 10 (alliance-scoped daily statistics)
-- Adds new profile-aware RPCs. Legacy NOX7 RPCs remain unchanged.
-- Direct daily-stat reads are restricted to the caller's active alliance profiles.

begin;

-- A member may submit or resubmit only their own active profile's daily stats.
create or replace function public.alliance_submit_daily_stats(
  p_actor_profile_id uuid,
  p_report_date date,
  p_vs_points bigint,
  p_donation_points bigint,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_report_date is null
     or p_vs_points is null or p_vs_points < 0
     or p_donation_points is null or p_donation_points < 0
     or (p_note is not null and char_length(p_note) > 250) then
    raise exception 'Ungültige Statistikwerte';
  end if;

  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_alliance_id is null then
    raise exception 'Aktives Spielerprofil gehört nicht zu diesem Konto';
  end if;

  insert into public.nox7_daily_stats
    (user_id, alliance_id, report_date, vs_points, donation_points,
     note, status, reviewed_by, review_note)
  values
    (p_actor_profile_id, v_alliance_id, p_report_date, p_vs_points,
     p_donation_points, nullif(btrim(p_note), ''), 'pending', null, null)
  on conflict (user_id, report_date)
  do update set
    alliance_id = excluded.alliance_id,
    vs_points = excluded.vs_points,
    donation_points = excluded.donation_points,
    note = excluded.note,
    status = 'pending',
    reviewed_by = null,
    review_note = null,
    submitted_at = now();
end;
$function$;

-- R4/R5 (or the fixed platform administrator) may enter approved stats
-- for an active member, but never across alliance boundaries.
create or replace function public.alliance_record_daily_stats_for_member(
  p_actor_profile_id uuid,
  p_target_profile_id uuid,
  p_report_date date,
  p_vs_points bigint,
  p_donation_points bigint,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor_alliance_id uuid;
  v_actor_rank text;
  v_target_alliance_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_report_date is null
     or p_vs_points is null or p_vs_points < 0
     or p_donation_points is null or p_donation_points < 0
     or (p_note is not null and char_length(p_note) > 250) then
    raise exception 'Ungültige Statistikwerte';
  end if;

  select p.alliance_id, p.game_rank
    into v_actor_alliance_id, v_actor_rank
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_actor_alliance_id is null then
    raise exception 'Aktives ausführendes Profil nicht gefunden';
  end if;

  select p.alliance_id into v_target_alliance_id
  from public.profiles p
  where p.id = p_target_profile_id
    and p.status = 'active'
    and p.role <> 'admin';

  if v_target_alliance_id is null then
    raise exception 'Aktives Zielmitglied nicht gefunden';
  end if;

  if not public.nox7_is_primary_admin()
     and (v_actor_alliance_id <> v_target_alliance_id
          or v_actor_rank not in ('R4','R5')) then
    raise exception 'Nur R4/R5 dürfen Statistiken innerhalb der eigenen Allianz eintragen';
  end if;

  if public.nox7_is_primary_admin()
     and v_target_alliance_id is null then
    raise exception 'Zielmitglied nicht gefunden';
  end if;

  insert into public.nox7_daily_stats
    (user_id, alliance_id, report_date, vs_points, donation_points,
     note, status, reviewed_by, review_note)
  values
    (p_target_profile_id, v_target_alliance_id, p_report_date, p_vs_points,
     p_donation_points, nullif(btrim(p_note), ''), 'approved',
     p_actor_profile_id, null)
  on conflict (user_id, report_date)
  do update set
    alliance_id = excluded.alliance_id,
    vs_points = excluded.vs_points,
    donation_points = excluded.donation_points,
    note = excluded.note,
    status = 'approved',
    reviewed_by = excluded.reviewed_by,
    review_note = null,
    submitted_at = now();
end;
$function$;

-- Review a pending entry only when it belongs to the actor's alliance.
create or replace function public.alliance_review_daily_stats(
  p_actor_profile_id uuid,
  p_entry_id uuid,
  p_approved boolean,
  p_review_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor_alliance_id uuid;
  v_actor_rank text;
  v_entry_alliance_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_approved is null or (p_review_note is not null and char_length(p_review_note) > 500) then
    raise exception 'Ungültige Prüfungsangaben';
  end if;

  select p.alliance_id, p.game_rank
    into v_actor_alliance_id, v_actor_rank
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_actor_alliance_id is null then
    raise exception 'Aktives ausführendes Profil nicht gefunden';
  end if;

  select s.alliance_id into v_entry_alliance_id
  from public.nox7_daily_stats s
  where s.id = p_entry_id
    and s.status = 'pending';

  if v_entry_alliance_id is null then
    raise exception 'Offene Statistikmeldung nicht gefunden';
  end if;

  if not public.nox7_is_primary_admin()
     and (v_actor_alliance_id <> v_entry_alliance_id
          or v_actor_rank not in ('R4','R5')) then
    raise exception 'Keine Berechtigung für diese Allianz';
  end if;

  update public.nox7_daily_stats
  set status = case when p_approved then 'approved' else 'rejected' end,
      reviewed_by = p_actor_profile_id,
      review_note = nullif(btrim(p_review_note), '')
  where id = p_entry_id
    and alliance_id = v_entry_alliance_id
    and status = 'pending';

  if not found then
    raise exception 'Statistikmeldung wurde inzwischen geändert';
  end if;
end;
$function$;

-- Correct values only inside the actor's alliance.
create or replace function public.alliance_update_daily_stats_values(
  p_actor_profile_id uuid,
  p_entry_id uuid,
  p_vs_points bigint,
  p_donation_points bigint,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor_alliance_id uuid;
  v_actor_rank text;
  v_entry_alliance_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_vs_points is null or p_vs_points < 0
     or p_donation_points is null or p_donation_points < 0
     or (p_note is not null and char_length(p_note) > 250) then
    raise exception 'Ungültige Statistikwerte';
  end if;

  select p.alliance_id, p.game_rank
    into v_actor_alliance_id, v_actor_rank
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_actor_alliance_id is null then
    raise exception 'Aktives ausführendes Profil nicht gefunden';
  end if;

  select s.alliance_id into v_entry_alliance_id
  from public.nox7_daily_stats s
  where s.id = p_entry_id;

  if v_entry_alliance_id is null then
    raise exception 'Statistikeintrag nicht gefunden';
  end if;

  if not public.nox7_is_primary_admin()
     and (v_actor_alliance_id <> v_entry_alliance_id
          or v_actor_rank not in ('R4','R5')) then
    raise exception 'Keine Berechtigung für diese Allianz';
  end if;

  update public.nox7_daily_stats
  set vs_points = p_vs_points,
      donation_points = p_donation_points,
      note = nullif(btrim(p_note), '')
  where id = p_entry_id
    and alliance_id = v_entry_alliance_id;

  if not found then
    raise exception 'Statistikeintrag konnte nicht geändert werden';
  end if;
end;
$function$;

-- Replace legacy broad SELECT policies with a tenant-aware read policy.
-- Approved rows are visible to active members of that alliance; pending and
-- rejected rows are visible to their owner and alliance managers only.
do $policy_cleanup$
declare
  v_policy record;
begin
  for v_policy in
    select policyname
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'nox7_daily_stats'
  loop
    execute format(
      'drop policy %I on public.nox7_daily_stats',
      v_policy.policyname
    );
  end loop;
end
$policy_cleanup$;

create policy alliance_scoped_daily_stats_select
on public.nox7_daily_stats
for select
to authenticated
using (
  public.nox7_can_access_alliance(alliance_id)
  and (
    status = 'approved'
    or exists (
      select 1
      from public.profiles owner_profile
      where owner_profile.id = nox7_daily_stats.user_id
        and owner_profile.owner_id = auth.uid()
        and owner_profile.alliance_id = nox7_daily_stats.alliance_id
    )
    or public.nox7_can_manage_alliance(alliance_id, 'R4')
  )
);

-- The new RPCs are callable only by authenticated sessions.
revoke all on function public.alliance_submit_daily_stats(uuid,date,bigint,bigint,text) from public, anon;
revoke all on function public.alliance_record_daily_stats_for_member(uuid,uuid,date,bigint,bigint,text) from public, anon;
revoke all on function public.alliance_review_daily_stats(uuid,uuid,boolean,text) from public, anon;
revoke all on function public.alliance_update_daily_stats_values(uuid,uuid,bigint,bigint,text) from public, anon;

grant execute on function public.alliance_submit_daily_stats(uuid,date,bigint,bigint,text) to authenticated;
grant execute on function public.alliance_record_daily_stats_for_member(uuid,uuid,date,bigint,bigint,text) to authenticated;
grant execute on function public.alliance_review_daily_stats(uuid,uuid,boolean,text) to authenticated;
grant execute on function public.alliance_update_daily_stats_values(uuid,uuid,bigint,bigint,text) to authenticated;

commit;

-- Verification (run separately after applying):
-- select
--   to_regprocedure('public.alliance_submit_daily_stats(uuid,date,bigint,bigint,text)') is not null as submit_stats,
--   to_regprocedure('public.alliance_record_daily_stats_for_member(uuid,uuid,date,bigint,bigint,text)') is not null as record_for_member,
--   to_regprocedure('public.alliance_review_daily_stats(uuid,uuid,boolean,text)') is not null as review_stats,
--   to_regprocedure('public.alliance_update_daily_stats_values(uuid,uuid,bigint,bigint,text)') is not null as update_stats;
--
-- Check grants separately with has_function_privilege for authenticated and anon.
-- Exercise all operations using authenticated test accounts from distinct alliances
-- before wiring them into the frontend.
