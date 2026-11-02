-- =====================================================================
-- Owl Driver: learning progress (videos + quizzes)
-- Run once in Supabase SQL Editor AFTER supabase-setup.sql. Safe to re-run.
--
-- - Videos: the app counts only seconds actually watched (skipping ahead
--   doesn't count) and the server also checks that enough real time has
--   passed since the video was started.
-- - Quizzes: answers are graded here on the server; a resource is marked
--   complete only when every answer is right.
-- - Parents see everyone's progress; students see their own.
-- =====================================================================

create table if not exists public.od_progress (
  user_id       uuid not null references auth.users(id) on delete cascade,
  family_id     uuid not null references public.od_families(id) on delete cascade,
  item          text not null check (char_length(item) between 1 and 40),
  kind          text not null check (kind in ('video', 'quiz')),
  duration      int,
  started_at    timestamptz,
  completed_at  timestamptz,
  score         int,
  total         int,
  attempts      int not null default 0,
  primary key (user_id, item)
);
alter table public.od_progress enable row level security;
revoke all on public.od_progress from anon, authenticated;

-- Include learning progress in the shared state the app downloads.
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
    'progress', coalesce((
      select jsonb_agg(jsonb_build_object('userId', p.user_id, 'item', p.item, 'kind', p.kind,
                                          'startedAt', p.started_at, 'completedAt', p.completed_at,
                                          'score', p.score, 'total', p.total, 'attempts', p.attempts))
      from od_progress p
      where p.family_id = f.id and (p_member.role = 'parent' or p.user_id = p_member.user_id)), '[]'::jsonb),
    'serverTime', now()
  )
  from od_families f where f.id = p_member.family_id;
$$;

-- Called when a video starts playing. Records the first start time.
create or replace function public.od_start_video(p_item text, p_duration int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row();
begin
  insert into od_progress (user_id, family_id, item, kind, duration, started_at)
  values (m.user_id, m.family_id, p_item, 'video', greatest(coalesce(p_duration, 0), 30), now())
  on conflict (user_id, item) do update
    set duration = coalesce(od_progress.duration, excluded.duration),
        started_at = coalesce(od_progress.started_at, excluded.started_at);
  return od_state_for(m);
end $$;

-- Called when the app has seen at least 90% of the video actually play.
-- The server also requires that most of the video's length has passed in real time.
create or replace function public.od_complete_video(p_item text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row(); p od_progress%rowtype;
begin
  select * into p from od_progress where user_id = m.user_id and item = p_item;
  if not found or p.started_at is null then raise exception 'NOT_STARTED' using errcode = 'P0001'; end if;
  if p.completed_at is null then
    if extract(epoch from (now() - p.started_at)) < p.duration * 0.8 then
      raise exception 'TOO_FAST' using errcode = 'P0001';
    end if;
    update od_progress set completed_at = now() where user_id = m.user_id and item = p_item;
  end if;
  return od_state_for(m);
end $$;

-- Quizzes are graded here. The answer key lives only on the server.
create or replace function public.od_submit_quiz(p_item text, p_answers int[])
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m od_members%rowtype := od_me_row(); key int[]; correct int := 0; i int; passed boolean;
begin
  key := case p_item
    when 'quiz-gdl'   then array[1, 2, 2, 1]
    when 'quiz-zero'  then array[3, 1, 2]
    when 'quiz-log'   then array[1, 1, 1, 0]
    when 'quiz-ittd'  then array[1, 1]
    else null end;
  if key is null then raise exception 'BAD_QUIZ' using errcode = 'P0001'; end if;
  if p_answers is null or array_length(p_answers, 1) is distinct from array_length(key, 1) then
    raise exception 'ANSWER_ALL' using errcode = 'P0001';
  end if;
  for i in 1..array_length(key, 1) loop
    if p_answers[i] = key[i] then correct := correct + 1; end if;
  end loop;
  passed := correct = array_length(key, 1);
  insert into od_progress (user_id, family_id, item, kind, score, total, attempts, completed_at)
  values (m.user_id, m.family_id, p_item, 'quiz', correct, array_length(key, 1), 1, case when passed then now() end)
  on conflict (user_id, item) do update
    set attempts = od_progress.attempts + 1,
        score = greatest(coalesce(od_progress.score, 0), excluded.score),
        total = excluded.total,
        completed_at = coalesce(od_progress.completed_at, excluded.completed_at);
  return jsonb_build_object('passed', passed, 'correct', correct, 'total', array_length(key, 1), 'state', od_state_for(m));
end $$;

revoke all on function public.od_start_video(text, int) from public, anon;
revoke all on function public.od_complete_video(text) from public, anon;
revoke all on function public.od_submit_quiz(text, int[]) from public, anon;
grant execute on function public.od_start_video(text, int) to authenticated;
grant execute on function public.od_complete_video(text) to authenticated;
grant execute on function public.od_submit_quiz(text, int[]) to authenticated;
revoke all on function public.od_state_for(public.od_members) from public, anon, authenticated;
