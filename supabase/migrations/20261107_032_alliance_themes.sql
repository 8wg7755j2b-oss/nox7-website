-- Alliance Hub migration 032: per-alliance visual themes
begin;

alter table public.alliances
  add column if not exists theme_key text not null default 'nox7';

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.alliances'::regclass
      and conname = 'alliances_theme_key_check'
  ) then
    alter table public.alliances
      add constraint alliances_theme_key_check
      check (theme_key in ('nox7','crimson','emerald','royal','arctic'));
  end if;
end
$migration$;

create or replace function public.alliance_get_theme(p_actor_profile_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_theme_key text;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_alliance_id is null then
    raise exception 'Ungültiges aktives Spielerprofil';
  end if;

  select a.theme_key into v_theme_key
  from public.alliances a
  where a.id = v_alliance_id;

  return coalesce(v_theme_key, 'nox7');
end;
$function$;

create or replace function public.alliance_set_theme(
  p_actor_profile_id uuid,
  p_theme_key text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_rank text;
begin
  if auth.uid() is null then
    raise exception 'Anmeldung erforderlich';
  end if;

  if p_theme_key is null
     or p_theme_key not in ('nox7','crimson','emerald','royal','arctic') then
    raise exception 'Ungültiges Allianz-Theme';
  end if;

  select p.alliance_id, p.game_rank
    into v_alliance_id, v_rank
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_alliance_id is null then
    raise exception 'Ungültiges aktives Spielerprofil';
  end if;

  if not public.nox7_is_primary_admin() and v_rank <> 'R5' then
    raise exception 'Nur R5 darf das Allianz-Design ändern';
  end if;

  update public.alliances
  set theme_key = p_theme_key
  where id = v_alliance_id;

  if not found then
    raise exception 'Allianz nicht gefunden';
  end if;
end;
$function$;

revoke all on function public.alliance_get_theme(uuid) from public, anon;
revoke all on function public.alliance_set_theme(uuid,text) from public, anon;
grant execute on function public.alliance_get_theme(uuid) to authenticated;
grant execute on function public.alliance_set_theme(uuid,text) to authenticated;

commit;
