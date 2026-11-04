-- NOX7 multi-alliance migration: stage 12 (alliance settings and news)
-- Additive RPC layer; existing NOX7 frontend and legacy RPCs remain unchanged.

begin;

create or replace function public.alliance_get_site_settings(
  p_actor_profile_id uuid
)
returns table (setting_key text, setting_value boolean)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;

  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_alliance_id is null then
    raise exception 'Ungültiges aktives Spielerprofil';
  end if;

  return query
  select s.setting_key, s.setting_value
  from public.alliance_site_settings s
  where s.alliance_id = v_alliance_id
  order by s.setting_key;
end;
$function$;

create or replace function public.alliance_set_site_setting(
  p_actor_profile_id uuid,
  p_setting_key text,
  p_setting_value boolean
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
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  if p_setting_key is null or p_setting_key !~ '^[a-z][a-z0-9_]{1,63}$'
     or p_setting_value is null then
    raise exception 'Ungültige Einstellung';
  end if;

  select p.alliance_id, p.game_rank into v_alliance_id, v_rank
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_alliance_id is null then raise exception 'Ungültiges aktives Spielerprofil'; end if;
  if not public.nox7_is_primary_admin() and v_rank <> 'R5' then
    raise exception 'Nur R5 darf Allianz-Einstellungen ändern';
  end if;

  insert into public.alliance_site_settings
    (alliance_id, setting_key, setting_value, updated_at, updated_by)
  values (v_alliance_id, p_setting_key, p_setting_value, now(), p_actor_profile_id)
  on conflict (alliance_id, setting_key)
  do update set setting_value = excluded.setting_value,
                updated_at = now(),
                updated_by = excluded.updated_by;
end;
$function$;

create or replace function public.alliance_list_posts(
  p_actor_profile_id uuid,
  p_limit integer default 30
)
returns table (
  post_id uuid,
  title text,
  body text,
  kind text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;

  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_alliance_id is null then raise exception 'Ungültiges aktives Spielerprofil'; end if;

  return query
  select n.id, n.title, n.body, n.kind, n.created_at
  from public.posts n
  where n.alliance_id = v_alliance_id
  order by n.created_at desc
  limit greatest(1, least(coalesce(p_limit,30),100));
end;
$function$;

create or replace function public.alliance_create_post(
  p_actor_profile_id uuid,
  p_title text,
  p_body text,
  p_kind text default 'news'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_rank text;
  v_post_id uuid;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  if p_title is null or char_length(btrim(p_title)) not between 2 and 120
     or p_body is null or char_length(btrim(p_body)) not between 2 and 10000
     or p_kind not in ('news','event') then
    raise exception 'Ungültiger Beitrag: Titel, Inhalt oder Typ prüfen';
  end if;

  select p.alliance_id, p.game_rank into v_alliance_id, v_rank
  from public.profiles p
  where p.id = p_actor_profile_id
    and p.owner_id = auth.uid()
    and p.status = 'active';

  if v_alliance_id is null then raise exception 'Ungültiges aktives Spielerprofil'; end if;
  if not public.nox7_is_primary_admin() and v_rank not in ('R4','R5') then
    raise exception 'Nur R4 oder R5 darf Beiträge veröffentlichen';
  end if;

  insert into public.posts (alliance_id, title, body, kind)
  values (v_alliance_id, btrim(p_title), btrim(p_body), p_kind)
  returning id into v_post_id;

  return v_post_id;
end;
$function$;

revoke all on function public.alliance_get_site_settings(uuid) from public, anon;
revoke all on function public.alliance_set_site_setting(uuid,text,boolean) from public, anon;
revoke all on function public.alliance_list_posts(uuid,integer) from public, anon;
revoke all on function public.alliance_create_post(uuid,text,text,text) from public, anon;

grant execute on function public.alliance_get_site_settings(uuid) to authenticated;
grant execute on function public.alliance_set_site_setting(uuid,text,boolean) to authenticated;
grant execute on function public.alliance_list_posts(uuid,integer) to authenticated;
grant execute on function public.alliance_create_post(uuid,text,text,text) to authenticated;

commit;

-- Verification:
-- SELECT p.proname,
--   has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_ok,
--   has_function_privilege('anon',p.oid,'EXECUTE') AS anon_ok
-- FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public' AND p.proname IN (
--   'alliance_get_site_settings','alliance_set_site_setting',
--   'alliance_list_posts','alliance_create_post'
-- ) ORDER BY p.proname;
