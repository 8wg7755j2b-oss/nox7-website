-- NOX7: Allow fixed Last War squad type choices, including Mix.
alter table public.profiles
  drop constraint if exists profiles_squad1_type_check,
  drop constraint if exists profiles_squad2_type_check,
  drop constraint if exists profiles_squad3_type_check;

alter table public.profiles
  add constraint profiles_squad1_type_check check (squad1_type is null or squad1_type in ('Panzer','Rakete','Flugzeug','Mix')),
  add constraint profiles_squad2_type_check check (squad2_type is null or squad2_type in ('Panzer','Rakete','Flugzeug','Mix')),
  add constraint profiles_squad3_type_check check (squad3_type is null or squad3_type in ('Panzer','Rakete','Flugzeug','Mix'));
