-- Platform admin: list every registered auth account, including accounts without alliance profiles.
begin;

create or replace function public.platform_admin_accounts()
returns table(
  user_id uuid,
  username text,
  created_at timestamptz,
  last_sign_in_at timestamptz,
  profile_count bigint,
  alliance_names text,
  is_banned boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
begin
  perform public.platform_admin_guard();

  return query
  select
    u.id,
    coalesce(
      nullif(btrim(u.raw_user_meta_data->>'username'), ''),
      nullif(btrim(u.raw_user_meta_data->>'display_name'), ''),
      split_part(coalesce(u.email, ''), '@', 1),
      'Unbenanntes Konto'
    )::text,
    u.created_at,
    u.last_sign_in_at,
    coalesce(p.profile_count, 0)::bigint,
    p.alliance_names,
    (u.banned_until is not null and u.banned_until > now()) as is_banned
  from auth.users u
  left join lateral (
    select
      count(*)::bigint as profile_count,
      string_agg(distinct a.name, ', ' order by a.name) as alliance_names
    from public.profiles pr
    left join public.alliances a on a.id = pr.alliance_id
    where pr.owner_id = u.id
  ) p on true
  order by u.created_at desc;
end;
$function$;

revoke all on function public.platform_admin_accounts() from public, anon;
grant execute on function public.platform_admin_accounts() to authenticated;

commit;
