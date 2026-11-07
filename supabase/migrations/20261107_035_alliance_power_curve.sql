-- Alliance Hub: historische Allianz-Kampfkraftkurve
begin;

create or replace function public.alliance_get_power_curve(
  p_actor_profile_id uuid,
  p_days integer default 30
)
returns table (
  record_date date,
  total_power bigint,
  members_with_history integer
)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_alliance_id uuid;
  v_days integer := greatest(7, least(coalesce(p_days, 30), 3650));
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
    raise exception 'Aktives Spielerprofil gehört nicht zu diesem Konto';
  end if;

  return query
  select d.day::date,
         sum(h.power)::bigint,
         count(h.power)::integer
  from generate_series(
    current_date - (v_days - 1),
    current_date,
    interval '1 day'
  ) as d(day)
  join public.profiles p
    on p.alliance_id = v_alliance_id
   and p.status = 'active'
  left join lateral (
    select ph.power
    from public.nox7_power_history ph
    where ph.user_id = p.id
      and ph.alliance_id = v_alliance_id
      and ph.recorded_at < (d.day + interval '1 day')
    order by ph.recorded_at desc
    limit 1
  ) h on true
  group by d.day
  having count(h.power) > 0
  order by d.day;
end;
$function$;

revoke all on function public.alliance_get_power_curve(uuid,integer) from public, anon;
grant execute on function public.alliance_get_power_curve(uuid,integer) to authenticated;

commit;
