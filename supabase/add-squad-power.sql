-- NOX7: Last War Squad combat power fields
alter table public.profiles
  add column if not exists squad1_power bigint,
  add column if not exists squad2_power bigint,
  add column if not exists squad3_power bigint;

comment on column public.profiles.squad1_power is 'Last War Squad 1 combat power';
comment on column public.profiles.squad2_power is 'Last War Squad 2 combat power';
comment on column public.profiles.squad3_power is 'Last War Squad 3 combat power';
