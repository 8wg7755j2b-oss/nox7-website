-- NOX7 platform admin: allow safe deletion of unused invitation codes.
begin;

create or replace function public.platform_admin_delete_invite(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alliance_id uuid;
begin
  perform public.platform_admin_guard();

  select alliance_id into v_alliance_id
  from public.alliance_invitation_codes
  where id = p_invitation_id
  for update;

  if not found then
    raise exception 'Einladungscode wurde nicht gefunden.';
  end if;

  if exists (
    select 1 from public.alliance_join_requests
    where invitation_id = p_invitation_id
  ) then
    raise exception 'Dieser Code ist mit Beitrittsanfragen verknüpft und bleibt zur Nachvollziehbarkeit erhalten. Bitte stattdessen widerrufen.';
  end if;

  delete from public.alliance_invitation_codes
  where id = p_invitation_id;

  perform public.platform_admin_log(
    'invite.delete',
    'invitation',
    p_invitation_id::text,
    jsonb_build_object('alliance_id', v_alliance_id)
  );
end;
$$;

revoke all on function public.platform_admin_delete_invite(uuid) from public, anon;
grant execute on function public.platform_admin_delete_invite(uuid) to authenticated;

commit;
