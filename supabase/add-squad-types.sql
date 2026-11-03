-- NOX7: Last War Squad type fields
-- Run once in the Supabase SQL Editor.
alter table public.profiles
  add column if not exists squad1_type text,
  add column if not exists squad2_type text,
  add column if not exists squad3_type text;

alter table public.profiles
  add constraint profiles_squad1_type_check check (squad1_type is null or squad1_type in ('Panzer','Flugzeug','Rakete')),
  add constraint profiles_squad2_type_check check (squad2_type is null or squad2_type in ('Panzer','Flugzeug','Rakete')),
  add constraint profiles_squad3_type_check check (squad3_type is null or squad3_type in ('Panzer','Flugzeug','Rakete'));
