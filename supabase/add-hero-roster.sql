-- NOX7: Save all 15 heroes and their gear per member
alter table public.profiles
  add column if not exists squad_heroes jsonb not null default '[[],[],[]]'::jsonb;

comment on column public.profiles.squad_heroes is
  'Three squads, five heroes each; each hero stores name and Waffe/Rüstung/Chip/Radar stars and level.';
