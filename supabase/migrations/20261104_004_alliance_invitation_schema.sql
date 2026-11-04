-- NOX7 multi-alliance migration: stage 4 (alliance-scoped invitation schema)
-- Additive schema only. Does not change the current signup trigger, legacy NOX7
-- invitation functions, frontend, or Vercel deployment.
-- New invitation flows must not be enabled until the matching RPCs and UI ship.

begin;

create table if not exists public.alliance_invitation_codes (
  id uuid primary key default gen_random_uuid(),
  alliance_id uuid not null references public.alliances(id) on delete cascade,
  code_hash text not null unique,
  created_by_profile_id uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  max_uses integer not null default 1,
  uses_count integer not null default 0,
  revoked_at timestamptz,
  constraint alliance_invitation_codes_max_uses_check
    check (max_uses between 1 and 500),
  constraint alliance_invitation_codes_uses_count_check
    check (uses_count >= 0)
);

create index if not exists alliance_invitation_codes_alliance_idx
  on public.alliance_invitation_codes(alliance_id);

create table if not exists public.alliance_invitation_reservations (
  email text not null,
  alliance_id uuid not null references public.alliances(id) on delete cascade,
  invitation_id uuid not null references public.alliance_invitation_codes(id) on delete cascade,
  reserved_at timestamptz not null default now(),
  expires_at timestamptz not null,
  primary key (email, alliance_id)
);

create index if not exists alliance_invitation_reservations_invitation_idx
  on public.alliance_invitation_reservations(invitation_id);

create index if not exists alliance_invitation_reservations_expiry_idx
  on public.alliance_invitation_reservations(expires_at);

create table if not exists public.alliance_join_requests (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null unique references public.profiles(id) on delete cascade,
  alliance_id uuid not null references public.alliances(id) on delete cascade,
  invitation_id uuid not null references public.alliance_invitation_codes(id),
  email text not null,
  requested_at timestamptz not null default now(),
  status text not null default 'pending',
  reviewed_by_profile_id uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  constraint alliance_join_requests_status_check
    check (status = any (array['pending','approved','rejected'])),
  constraint alliance_join_requests_owner_alliance_key
    unique (owner_id, alliance_id)
);

create index if not exists alliance_join_requests_alliance_status_idx
  on public.alliance_join_requests(alliance_id, status, requested_at);

create index if not exists alliance_join_requests_profile_idx
  on public.alliance_join_requests(profile_id);

-- Browser clients must use narrowly scoped SECURITY DEFINER RPCs in a later
-- migration. No direct table access is granted in this schema-only stage.
alter table public.alliance_invitation_codes enable row level security;
alter table public.alliance_invitation_reservations enable row level security;
alter table public.alliance_join_requests enable row level security;

revoke all on table public.alliance_invitation_codes from anon, authenticated;
revoke all on table public.alliance_invitation_reservations from anon, authenticated;
revoke all on table public.alliance_join_requests from anon, authenticated;

commit;

-- Verification (run separately after applying):
-- select table_name
-- from information_schema.tables
-- where table_schema = 'public'
--   and table_name in (
--     'alliance_invitation_codes',
--     'alliance_invitation_reservations',
--     'alliance_join_requests'
--   )
-- order by table_name;
--
-- select tablename, rowsecurity
-- from pg_tables
-- where schemaname = 'public'
--   and tablename in (
--     'alliance_invitation_codes',
--     'alliance_invitation_reservations',
--     'alliance_join_requests'
--   )
-- order by tablename;
