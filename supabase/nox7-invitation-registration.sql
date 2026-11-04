-- NOX7 invitation-only registration with mandatory ADMIN approval.
-- Run once in Supabase SQL Editor. Existing active members remain active.
create extension if not exists pgcrypto;

alter table public.profiles alter column status set default 'pending';

create table if not exists public.nox7_invitation_codes (
  id uuid primary key default gen_random_uuid(),
  code_hash text not null unique,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  max_uses integer not null default 1 check (max_uses between 1 and 500),
  uses_count integer not null default 0 check (uses_count >= 0),
  revoked_at timestamptz
);

create table if not exists public.nox7_invitation_reservations (
  email text primary key,
  invitation_id uuid not null references public.nox7_invitation_codes(id) on delete cascade,
  reserved_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours'
);

-- Extend the existing profile status domain without changing existing member states.
do $
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid='public.profiles'::regclass and contype='c'
      and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.profiles drop constraint %I',c.conname);
  end loop;
end $;
alter table public.profiles add constraint profiles_status_check
  check (status in ('active','left','kicked','transferred','pending','rejected'));

create table if not exists public.nox7_registration_requests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  invitation_id uuid not null references public.nox7_invitation_codes(id),
  email text not null,
  requested_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_note text
);

alter table public.nox7_invitation_codes enable row level security;
alter table public.nox7_invitation_reservations enable row level security;
alter table public.nox7_registration_requests enable row level security;
revoke all on public.nox7_invitation_codes, public.nox7_invitation_reservations, public.nox7_registration_requests from anon, authenticated;

create or replace function public.nox7_is_primary_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.id = '9cd89136-4682-4e6a-84ba-43c41327fa93'::uuid
      and p.role = 'admin'
      and p.status = 'active'
  );
$$;
revoke all on function public.nox7_is_primary_admin() from public;
grant execute on function public.nox7_is_primary_admin() to authenticated;

create or replace function public.reserve_nox7_invitation(p_email text, p_code text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_code public.nox7_invitation_codes%rowtype; v_email text;
begin
  v_email := lower(trim(p_email));
  if v_email is null or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or length(trim(coalesce(p_code,''))) < 6 then
    return jsonb_build_object('ok',false,'message','Bitte E-Mail-Adresse und Einladungscode prüfen.');
  end if;
  select * into v_code from public.nox7_invitation_codes
  where code_hash = encode(extensions.digest(upper(trim(p_code)), 'sha256'),'hex')
    and revoked_at is null
    and (expires_at is null or expires_at > now())
  for update;
  if not found then return jsonb_build_object('ok',false,'message','Einladungscode ungültig oder abgelaufen.'); end if;
  delete from public.nox7_invitation_reservations where expires_at <= now();
  if v_code.uses_count + (select count(*) from public.nox7_invitation_reservations r where r.invitation_id=v_code.id) >= v_code.max_uses then
    return jsonb_build_object('ok',false,'message','Dieser Einladungscode wurde bereits vollständig verwendet.');
  end if;
  insert into public.nox7_invitation_reservations(email,invitation_id,expires_at)
  values(v_email,v_code.id,now()+interval '24 hours')
  on conflict(email) do update set invitation_id=excluded.invitation_id,reserved_at=now(),expires_at=excluded.expires_at;
  return jsonb_build_object('ok',true,'message','Einladungscode bestätigt.');
end;
$$;
revoke all on function public.reserve_nox7_invitation(text,text) from public;
grant execute on function public.reserve_nox7_invitation(text,text) to anon, authenticated;

create or replace function public.finalize_nox7_registration()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_email text; v_res public.nox7_invitation_reservations%rowtype; v_profile_status text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'message','Anmeldung erforderlich.'); end if;
  v_email := lower(coalesce(auth.jwt()->>'email',''));
  select * into v_res from public.nox7_invitation_reservations
    where email=v_email and expires_at>now() for update;
  if not found then
    select status into v_profile_status from public.profiles where id=auth.uid();
    return jsonb_build_object('ok',true,'status',coalesce(v_profile_status,'pending'),'already_processed',true);
  end if;
  insert into public.nox7_registration_requests(user_id,invitation_id,email)
    values(auth.uid(),v_res.invitation_id,v_email)
    on conflict(user_id) do nothing;
  update public.nox7_invitation_codes set uses_count=uses_count+1 where id=v_res.invitation_id;
  update public.profiles set status='pending' where id=auth.uid();
  delete from public.nox7_invitation_reservations where email=v_email;
  return jsonb_build_object('ok',true,'status','pending','message','Registrierung wartet auf Admin-Freigabe.');
end;
$$;
revoke all on function public.finalize_nox7_registration() from public;
grant execute on function public.finalize_nox7_registration() to authenticated;

create or replace function public.admin_create_nox7_invitation(p_max_uses integer default 1, p_expires_at timestamptz default null)
returns text language plpgsql security definer set search_path = ''
as $$
declare v_code text;
begin
  if not public.nox7_is_primary_admin() then raise exception 'Nur der ADMIN darf Einladungscodes erstellen.'; end if;
  if p_max_uses is null or p_max_uses < 1 or p_max_uses > 500 then raise exception 'Ungültige Anzahl.'; end if;
  v_code := 'NOX7-' || upper(encode(extensions.gen_random_bytes(5),'hex'));
  insert into public.nox7_invitation_codes(code_hash,created_by,max_uses,expires_at)
    values(encode(extensions.digest(v_code,'sha256'),'hex'),auth.uid(),p_max_uses,p_expires_at);
  return v_code;
end;
$$;
revoke all on function public.admin_create_nox7_invitation(integer,timestamptz) from public;
grant execute on function public.admin_create_nox7_invitation(integer,timestamptz) to authenticated;

create or replace function public.admin_list_nox7_registration_requests()
returns table(user_id uuid,email text,display_name text,requested_at timestamptz,invitation_id uuid)
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.nox7_is_primary_admin() then raise exception 'Keine Berechtigung.'; end if;
  return query
    select r.user_id,r.email,p.display_name,r.requested_at,r.invitation_id
    from public.nox7_registration_requests r
    left join public.profiles p on p.id=r.user_id
    where r.status='pending' order by r.requested_at asc;
end;
$$;
revoke all on function public.admin_list_nox7_registration_requests() from public;
grant execute on function public.admin_list_nox7_registration_requests() to authenticated;

create or replace function public.admin_review_nox7_registration(p_user_id uuid,p_approve boolean,p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not public.nox7_is_primary_admin() then raise exception 'Nur der ADMIN darf Registrierungen freigeben.'; end if;
  if not exists(select 1 from public.nox7_registration_requests where user_id=p_user_id and status='pending') then
    raise exception 'Keine offene Registrierungsanfrage gefunden.';
  end if;
  update public.nox7_registration_requests
    set status=case when p_approve then 'approved' else 'rejected' end,
        reviewed_by=auth.uid(),reviewed_at=now(),review_note=left(coalesce(p_note,''),500)
    where user_id=p_user_id;
  update public.profiles set status=case when p_approve then 'active' else 'rejected' end where id=p_user_id;
  return jsonb_build_object('ok',true,'status',case when p_approve then 'active' else 'rejected' end);
end;
$$;
revoke all on function public.admin_review_nox7_registration(uuid,boolean,text) from public;
grant execute on function public.admin_review_nox7_registration(uuid,boolean,text) to authenticated;
