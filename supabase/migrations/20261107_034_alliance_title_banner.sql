-- Alliance Hub migration 034: per-alliance title banner
begin;

alter table public.alliances
  add column if not exists banner_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('alliance-banners', 'alliance-banners', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
set public = true,
    file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "Alliance banners are publicly readable" on storage.objects;
create policy "Alliance banners are publicly readable"
on storage.objects for select
to public
using (bucket_id = 'alliance-banners');

drop policy if exists "R5 can upload alliance banners" on storage.objects;
create policy "R5 can upload alliance banners"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'alliance-banners'
  and exists (
    select 1 from public.profiles p
    where p.alliance_id::text = (storage.foldername(name))[1]
      and p.owner_id = auth.uid()
      and p.status = 'active'
      and p.game_rank = 'R5'
  )
);

drop policy if exists "R5 can update alliance banners" on storage.objects;
create policy "R5 can update alliance banners"
on storage.objects for update
to authenticated
using (
  bucket_id = 'alliance-banners'
  and exists (
    select 1 from public.profiles p
    where p.alliance_id::text = (storage.foldername(name))[1]
      and p.owner_id = auth.uid()
      and p.status = 'active'
      and p.game_rank = 'R5'
  )
)
with check (
  bucket_id = 'alliance-banners'
  and exists (
    select 1 from public.profiles p
    where p.alliance_id::text = (storage.foldername(name))[1]
      and p.owner_id = auth.uid()
      and p.status = 'active'
      and p.game_rank = 'R5'
  )
);

create or replace function public.alliance_get_banner(p_actor_profile_id uuid)
returns text
language plpgsql stable security definer set search_path = ''
as $function$
declare v_alliance_id uuid; v_path text;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  select p.alliance_id into v_alliance_id
  from public.profiles p
  where p.id = p_actor_profile_id and p.owner_id = auth.uid() and p.status = 'active';
  if v_alliance_id is null then raise exception 'Ungültiges aktives Spielerprofil'; end if;
  select a.banner_path into v_path from public.alliances a where a.id = v_alliance_id;
  return v_path;
end;
$function$;

create or replace function public.alliance_set_banner(p_actor_profile_id uuid, p_banner_path text)
returns void
language plpgsql security definer set search_path = ''
as $function$
declare v_alliance_id uuid; v_rank text;
begin
  if auth.uid() is null then raise exception 'Anmeldung erforderlich'; end if;
  if p_banner_path is not null and (length(p_banner_path) > 300 or p_banner_path !~ '^[0-9a-f-]{36}/banner[.](jpg|png|webp)$') then
    raise exception 'Ungültiger Titelbild-Pfad';
  end if;
  select p.alliance_id, p.game_rank into v_alliance_id, v_rank
  from public.profiles p
  where p.id = p_actor_profile_id and p.owner_id = auth.uid() and p.status = 'active';
  if v_alliance_id is null then raise exception 'Ungültiges aktives Spielerprofil'; end if;
  if not public.nox7_is_primary_admin() and v_rank <> 'R5' then raise exception 'Nur R5 darf das Titelbild ändern'; end if;
  update public.alliances set banner_path = p_banner_path where id = v_alliance_id;
end;
$function$;

revoke all on function public.alliance_get_banner(uuid) from public, anon;
revoke all on function public.alliance_set_banner(uuid,text) from public, anon;
grant execute on function public.alliance_get_banner(uuid) to authenticated;
grant execute on function public.alliance_set_banner(uuid,text) to authenticated;

commit;
