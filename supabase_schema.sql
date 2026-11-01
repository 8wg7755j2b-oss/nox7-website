-- NOX7 Datenbankschema für Supabase
-- Im Supabase Dashboard unter SQL Editor komplett ausführen.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'NOX7-Mitglied' check (char_length(display_name) <= 40),
  game_rank text not null default 'Mitglied' check (game_rank in ('Mitglied','R4','R5')),
  role text not null default 'member' check (role in ('member','r4','r5','admin')),
  power bigint,
  created_at timestamptz not null default now()
);

create table if not exists public.posts (
  id bigint generated always as identity primary key,
  title text not null,
  body text not null,
  kind text not null default 'news' check (kind in ('news','event')),
  created_at timestamptz not null default now(),
  author uuid references auth.users(id)
);

create table if not exists public.contact_messages (
  id bigint generated always as identity primary key,
  player_name text not null,
  contact text not null,
  message text not null,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.contact_messages enable row level security;

-- Neue Nutzer bekommen immer member-Rechte. Niemals Rolle aus dem Browser übernehmen.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role, game_rank)
  values (new.id, 'NOX7-Mitglied', 'member', 'Mitglied');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_nox7_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role in ('admin','r5','r4')
  );
$$;

-- Profile: öffentlich lesbar, Nutzer dürfen nur eigene Profilfelder ändern.
grant select on public.profiles to anon, authenticated;
grant update (display_name) on public.profiles to authenticated;
create policy "profiles are publicly readable"
on public.profiles for select to anon, authenticated using (true);
create policy "members update own profile"
on public.profiles for update to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

-- Posts: öffentlich lesbar, nur Allianzführung darf veröffentlichen/ändern/löschen.
grant select on public.posts to anon, authenticated;
grant insert, update, delete on public.posts to authenticated;
create policy "posts are public"
on public.posts for select to anon, authenticated using (true);
create policy "leadership manages posts"
on public.posts for all to authenticated
using ((select public.is_nox7_admin()))
with check ((select public.is_nox7_admin()));

-- Kontakt: jeder darf Nachricht senden, nur Führung darf lesen/löschen.
grant insert on public.contact_messages to anon, authenticated;
grant select, delete on public.contact_messages to authenticated;
create policy "visitors can submit contact"
on public.contact_messages for insert to anon, authenticated
with check (
  char_length(player_name) between 1 and 80
  and char_length(contact) between 1 and 120
  and char_length(message) between 1 and 3000
);
create policy "leadership reads contact"
on public.contact_messages for select to authenticated
using ((select public.is_nox7_admin()));
create policy "leadership deletes contact"
on public.contact_messages for delete to authenticated
using ((select public.is_nox7_admin()));

-- WICHTIG: Nach der ersten Registrierung eines vertrauenswürdigen Betreibers
-- dessen UUID in Authentication > Users kopieren und hier einsetzen:
-- update public.profiles set role = 'admin', game_rank = 'R5' where id = 'UUID-HIER-EINSETZEN';
