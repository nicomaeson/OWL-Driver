-- =====================================================================
-- Owl Driver: Supabase database setup (accounts + roles)
-- Run once in Supabase: SQL Editor -> New query -> paste all -> Run.
-- Safe to run again: it keeps your data and replaces the functions.
-- =====================================================================
--
-- How security works
-- - Everyone signs in with their own Supabase account (email + password,
--   then optionally a passkey for fingerprint / face sign-in).
-- - A family has two invite codes. Joining with the PARENT code makes you
--   a parent; joining with the STUDENT code makes you a student.
-- - The tables can't be read or changed directly. Every action goes
--   through the functions below, which look up who is signed in
--   (auth.uid()) and their role.
-- - Only parents can approve, unapprove, delete approved drives, clear the
--   log, see invite codes, or remove members.
-- - Every drive starts as Pending, and the 2-hour daily cap is applied
--   here on the server.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Tables ----------
create table if not exists public.od_families (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (char_length(name) between 1 and 60),
  parent_invite   text unique not null,
  student_invite  text unique not null,
  checklist       jsonb not null default '[]'::jsonb,
  created_by      uuid not null,
  created_at      timestamptz not null default now()
);

create table if not exists public.od_members (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  family_id     uuid not null references public.od_families(id) on delete cascade,
  role          text not null check (role in ('parent', 'student')),
  display_name  text not null check (char_length(display_name) between 1 and 40),
  dl_number     text check (dl_number is null or char_length(dl_number) <= 20),
  created_at    timestamptz not null default now()
);
create index if not exists od_members_family on public.od_members (family_id);

create table if not exists public.od_entries (
  id             uuid primary key default gen_random_uuid(),
  family_id      uuid not null references public.od_families(id) on delete cascade,
  created_by     uuid,
  kind           text not null default 'practice' check (kind in ('practice', 'instruction', 'observation')),
  lesson         text check (lesson is null or char_length(lesson) <= 80),
  drive_date     date not null,
  start_time     time,
  supervisor     text not null check (char_length(supervisor) between 1 and 60),
  supervisor_dl  text check (supervisor_dl is null or char_length(supervisor_dl) <= 20),
  period         text not null check (period in ('Day', 'Night')),
  duration       numeric(3,1) not null check (duration >= 0.5 and duration <= 4),
  counted        numeric(3,1) not null check (counted >= 0 and counted <= 2),
  skills         text not null check (char_length(skills) between 1 and 200),
  status         text not null default 'pending' check (status in ('pending', 'approved')),
  approved_by    text,
  approved_by_id uuid,
  approved_at    timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists od_entries_family_date on public.od_entries (family_id, drive_date);

alter table public.od_families enable row level security;
alter table public.od_members  enable row level security;
alter table public.od_entries  enable row level security;
revoke all on public.od_families from anon, authenticated;
revoke all on public.od_members  from anon, authenticated;
revoke all on public.od_entries  from anon, authenticated;

-- ---------- Internal helpers (not callable by the app) ----------

-- The signed-in user's membership; raises if not signed in / not in a family.
create or replace function public.od_me_row()
returns public.od_members language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN' using errcode = 'P0001'; end if;
  select * into m from od_members where user_id = auth.uid();
  if not found then raise exception 'NO_FAMILY' using errcode = 'P0001'; end if;
  return m;
end $$;

create or replace function public.od_require_parent()
returns public.od_members language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row();
begin
  if m.role <> 'parent' then raise exception 'PARENT_ONLY' using errcode = 'P0001'; end if;
  return m;
end $$;

-- Readable invite code like "P-7KQ4-M2XD" (no 0/O/1/I to avoid confusion).
create or replace function public.od_new_invite(p_prefix text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := gen_random_bytes(8); s text := ''; i int;
begin
  for i in 0..7 loop
    s := s || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
    if i = 3 then s := s || '-'; end if;
  end loop;
  return p_prefix || '-' || s;
end $$;

-- Recompute "counted" for one day in the order drives were entered, so a
-- day never counts more than 2 hours.
create or replace function public.od_recount_day(p_family uuid, p_date date)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare r record; used numeric := 0; c numeric;
begin
  for r in select id, duration from od_entries
            where family_id = p_family and drive_date = p_date
            order by created_at, id loop
    c := least(r.duration, greatest(0, 2 - used));
    used := used + c;
    update od_entries set counted = c where id = r.id;
  end loop;
end $$;

create or replace function public.od_state_for(p_member public.od_members)
returns jsonb language sql security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'me', jsonb_build_object('userId', p_member.user_id, 'role', p_member.role,
                             'displayName', p_member.display_name, 'dlNumber', p_member.dl_number),
    'family', jsonb_build_object(
        'name', f.name,
        'parentInvite', case when p_member.role = 'parent' then f.parent_invite end,
        'studentInvite', case when p_member.role = 'parent' then f.student_invite end),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object('userId', m.user_id, 'role', m.role, 'displayName', m.display_name,
                                          'dlNumber', m.dl_number) order by m.role, m.created_at)
      from od_members m where m.family_id = f.id), '[]'::jsonb),
    'checklist', f.checklist,
    'entries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'kind', e.kind, 'lesson', e.lesson, 'date', e.drive_date, 'time', to_char(e.start_time, 'HH24:MI'),
        'supervisor', e.supervisor, 'supervisorDl', e.supervisor_dl, 'period', e.period,
        'duration', e.duration, 'counted', e.counted, 'skills', e.skills, 'status', e.status,
        'createdBy', e.created_by, 'approvedBy', e.approved_by, 'approvedAt', e.approved_at, 'createdAt', e.created_at
      ) order by e.drive_date, e.created_at)
      from od_entries e where e.family_id = f.id), '[]'::jsonb),
    'serverTime', now()
  )
  from od_families f where f.id = p_member.family_id;
$$;

-- ---------- App functions (signed-in users only) ----------

-- Who am I? Returns {"member": null} if signed in but not in a family yet.
create or replace function public.od_whoami()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN' using errcode = 'P0001'; end if;
  select * into m from od_members where user_id = auth.uid();
  if not found then return jsonb_build_object('member', null); end if;
  return od_state_for(m);
end $$;

-- Create a family; the creator becomes its first parent.
create or replace function public.od_create_family(p_family_name text, p_display_name text, p_dl_number text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare fid uuid; m od_members%rowtype;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN' using errcode = 'P0001'; end if;
  if exists (select 1 from od_members where user_id = auth.uid()) then
    raise exception 'ALREADY_IN_FAMILY' using errcode = 'P0001';
  end if;
  if char_length(trim(coalesce(p_display_name, ''))) < 1 then raise exception 'NAME_REQUIRED' using errcode = 'P0001'; end if;
  insert into od_families (name, parent_invite, student_invite, created_by)
  values (left(coalesce(nullif(trim(p_family_name), ''), 'Our family'), 60),
          od_new_invite('P'), od_new_invite('S'), auth.uid())
  returning id into fid;
  insert into od_members (user_id, family_id, role, display_name, dl_number)
  values (auth.uid(), fid, 'parent', left(trim(p_display_name), 40), nullif(left(upper(trim(coalesce(p_dl_number, ''))), 20), ''))
  returning * into m;
  return od_state_for(m);
end $$;

-- Join with an invite code. The code decides the role.
create or replace function public.od_join_family(p_invite text, p_display_name text, p_dl_number text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare f od_families%rowtype; r text; code text := upper(regexp_replace(coalesce(p_invite, ''), '\s', '', 'g')); m od_members%rowtype;
begin
  if auth.uid() is null then raise exception 'NOT_SIGNED_IN' using errcode = 'P0001'; end if;
  if exists (select 1 from od_members where user_id = auth.uid()) then
    raise exception 'ALREADY_IN_FAMILY' using errcode = 'P0001';
  end if;
  if char_length(trim(coalesce(p_display_name, ''))) < 1 then raise exception 'NAME_REQUIRED' using errcode = 'P0001'; end if;
  select * into f from od_families where parent_invite = code;
  if found then r := 'parent';
  else
    select * into f from od_families where student_invite = code;
    if found then r := 'student'; end if;
  end if;
  if r is null then raise exception 'BAD_INVITE' using errcode = 'P0001'; end if;
  insert into od_members (user_id, family_id, role, display_name, dl_number)
  values (auth.uid(), f.id, r, left(trim(p_display_name), 40), nullif(left(upper(trim(coalesce(p_dl_number, ''))), 20), ''))
  returning * into m;
  return od_state_for(m);
end $$;

create or replace function public.od_get_state()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  return od_state_for(od_me_row());
end $$;

create or replace function public.od_update_profile(p_display_name text, p_dl_number text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row();
begin
  if char_length(trim(coalesce(p_display_name, ''))) < 1 then raise exception 'NAME_REQUIRED' using errcode = 'P0001'; end if;
  update od_members set display_name = left(trim(p_display_name), 40),
                        dl_number = nullif(left(upper(trim(coalesce(p_dl_number, ''))), 20), '')
   where user_id = m.user_id returning * into m;
  return od_state_for(m);
end $$;

-- Any family member can log a drive. It always starts Pending.
create or replace function public.od_add_entry(
  p_date date, p_time text, p_kind text, p_lesson text, p_supervisor text, p_supervisor_dl text,
  p_period text, p_duration numeric, p_skills text, p_client_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row();
begin
  if p_duration is null or p_duration < 0.5 or p_duration > 4 or (p_duration * 2) <> floor(p_duration * 2) then
    raise exception 'BAD_DURATION' using errcode = 'P0001';
  end if;
  if p_date > current_date + 1 then raise exception 'FUTURE_DATE' using errcode = 'P0001'; end if;
  if coalesce(p_kind, 'practice') not in ('practice', 'instruction', 'observation') then
    raise exception 'BAD_KIND' using errcode = 'P0001';
  end if;
  if p_client_id is not null and exists (select 1 from od_entries where id = p_client_id) then
    return od_state_for(m);   -- same offline submission sent twice
  end if;
  insert into od_entries (id, family_id, created_by, kind, lesson, drive_date, start_time, supervisor, supervisor_dl,
                          period, duration, counted, skills)
  values (coalesce(p_client_id, gen_random_uuid()), m.family_id, m.user_id, coalesce(p_kind, 'practice'),
          nullif(left(trim(coalesce(p_lesson, '')), 80), ''), p_date, nullif(p_time, '')::time,
          left(trim(p_supervisor), 60), nullif(left(upper(trim(coalesce(p_supervisor_dl, ''))), 20), ''),
          p_period, p_duration, 0, left(trim(p_skills), 200));
  perform od_recount_day(m.family_id, p_date);
  return od_state_for(m);
end $$;

-- Pending drives: the person who logged it or a parent can delete.
-- Approved drives: parents only.
create or replace function public.od_delete_entry(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row(); e od_entries%rowtype;
begin
  select * into e from od_entries where id = p_id and family_id = m.family_id;
  if not found then return od_state_for(m); end if;
  if m.role <> 'parent' and (e.status = 'approved' or e.created_by is distinct from m.user_id) then
    raise exception 'PARENT_ONLY' using errcode = 'P0001';
  end if;
  delete from od_entries where id = p_id;
  perform od_recount_day(m.family_id, e.drive_date);
  return od_state_for(m);
end $$;

create or replace function public.od_approve(p_ids uuid[])
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_require_parent();
begin
  update od_entries
     set status = 'approved', approved_by = m.display_name, approved_by_id = m.user_id, approved_at = now()
   where family_id = m.family_id and status = 'pending' and id = any(p_ids);
  return od_state_for(m);
end $$;

create or replace function public.od_unapprove(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_require_parent();
begin
  update od_entries set status = 'pending', approved_by = null, approved_by_id = null, approved_at = null
   where family_id = m.family_id and id = p_id;
  return od_state_for(m);
end $$;

create or replace function public.od_clear_log()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_require_parent();
begin
  delete from od_entries where family_id = m.family_id;
  return od_state_for(m);
end $$;

-- The checklist is shared; anyone in the family can tick it.
create or replace function public.od_set_checklist(p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row();
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 50 then
    raise exception 'BAD_CHECKLIST' using errcode = 'P0001';
  end if;
  update od_families set checklist = p_items where id = m.family_id;
  return od_state_for(m);
end $$;

-- Parents can issue fresh invite codes (old ones stop working).
create or replace function public.od_new_invites()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_require_parent();
begin
  update od_families set parent_invite = od_new_invite('P'), student_invite = od_new_invite('S') where id = m.family_id;
  return od_state_for(m);
end $$;

-- Parents can remove a member (not themselves).
create or replace function public.od_remove_member(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_require_parent();
begin
  if p_user = m.user_id then raise exception 'CANNOT_REMOVE_SELF' using errcode = 'P0001'; end if;
  delete from od_members where user_id = p_user and family_id = m.family_id;
  return od_state_for(m);
end $$;

-- Anyone can leave their family (a family's last parent cannot while others remain).
create or replace function public.od_leave_family()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row();
begin
  if m.role = 'parent' and (select count(*) from od_members where family_id = m.family_id and role = 'parent') = 1
     and exists (select 1 from od_members where family_id = m.family_id and user_id <> m.user_id) then
    raise exception 'LAST_PARENT' using errcode = 'P0001';
  end if;
  delete from od_members where user_id = m.user_id;
  return jsonb_build_object('member', null);
end $$;

-- ---------- Permissions ----------
revoke all on function public.od_me_row()                         from public, anon, authenticated;
revoke all on function public.od_require_parent()                 from public, anon, authenticated;
revoke all on function public.od_new_invite(text)                 from public, anon, authenticated;
revoke all on function public.od_recount_day(uuid, date)          from public, anon, authenticated;
revoke all on function public.od_state_for(public.od_members)     from public, anon, authenticated;

do $$
declare fn text;
begin
  foreach fn in array array[
    'od_whoami()',
    'od_create_family(text, text, text)',
    'od_join_family(text, text, text)',
    'od_get_state()',
    'od_update_profile(text, text)',
    'od_add_entry(date, text, text, text, text, text, text, numeric, text, uuid)',
    'od_delete_entry(uuid)',
    'od_approve(uuid[])',
    'od_unapprove(uuid)',
    'od_clear_log()',
    'od_set_checklist(jsonb)',
    'od_new_invites()',
    'od_remove_member(uuid)',
    'od_leave_family()'
  ] loop
    execute format('revoke all on function public.%s from public, anon', fn);
    execute format('grant execute on function public.%s to authenticated', fn);
  end loop;
end $$;
