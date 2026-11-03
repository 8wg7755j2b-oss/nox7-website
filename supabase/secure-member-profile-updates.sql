-- NOX7: Restrict profile writes to the signed-in member's own profile.
-- Privileged changes (rank, role, status and other members) must use the
-- existing SECURITY DEFINER RPC functions, never direct browser updates.

alter table public.profiles enable row level security;

-- Keep any existing permissive SELECT policy unchanged. These UPDATE policies
-- ensure an authenticated session can update only its own profile row.
drop policy if exists nox7_profiles_update_own on public.profiles;
create policy nox7_profiles_update_own
  on public.profiles
  as permissive
  for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

drop policy if exists nox7_profiles_update_own_guard on public.profiles;
create policy nox7_profiles_update_own_guard
  on public.profiles
  as restrictive
  for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Remove broad table-level UPDATE rights and allow only self-editable fields.
-- Rank, role, status, membership state and leadership controls are excluded.
revoke update on table public.profiles from public, anon, authenticated;
grant update (
  display_name,
  power,
  squad1_power,
  squad2_power,
  squad3_power,
  squad1_type,
  squad2_type,
  squad3_type,
  squad_heroes
) on table public.profiles to authenticated;
