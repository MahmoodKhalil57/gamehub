-- AI judge (applied as migration `ai_judge`). Requires secure_rooms.sql.
-- Adds a per-room judge choice (crowd vote or AI) for Dumb Laws and Art of the Deal.
-- When an AI-judged round ends, the room enters `judging`; the `judge` Edge Function
-- (supabase/functions/judge) claims it with judge_claim, asks Clef Flash on OpenRouter,
-- and records the verdict with judge_apply. If the judge fails or takes over 45s,
-- room_tick falls back to a crowd vote.
--
-- This migration also replaces room_tick and room_post (end of round now goes through
-- gh_private.end_round instead of gh_private.open_vote, and room_tick handles `judging`).
-- The full text of every function is in the project's migration history
-- (supabase_migrations.schema_migrations, name = 'ai_judge').

create function gh_private.end_round(p_code text, p_engine text, p_state jsonb, p_msg text, p_ms int) returns void language plpgsql set search_path = '' as $$
declare s jsonb := p_state; now_ms bigint := gh_private.ms();
begin
  if p_engine in ('laws', 'deal') and coalesce(p_state ->> 'judgeMode', 'crowd') = 'ai' then
    s := s || jsonb_build_object('phase', 'judging', 'judgeKey', gh_private.rid(), 'judgeClaimedAt', null, 'phaseAt', now_ms, 'endsAt', now_ms + 45000);
    perform gh_private.save(p_code, s);
    perform gh_private.say(p_code, s, 'sys', 'Time! The judge is deliberating…');
  else
    perform gh_private.open_vote(p_code, p_engine, p_state, p_msg, p_ms);
  end if;
end $$;

create function public.room_set_judge(p_code text, p_mode text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); eng text; s jsonb; h uuid;
begin
  select engine, state, host into eng, s, h from public.rooms where code = p_code for update;
  if h <> u then raise exception 'Only the host can do that.'; end if;
  if coalesce(s ->> 'phase', 'lobby') <> 'lobby' then raise exception 'Choose the judge in the lobby.'; end if;
  if eng not in ('laws', 'deal') then raise exception 'This game is always decided by the room.'; end if;
  if p_mode is null or p_mode not in ('crowd', 'ai') then raise exception 'Pick Crowd vote or AI judge.'; end if;
  perform gh_private.save(p_code, jsonb_set(s, '{judgeMode}', to_jsonb(p_mode)));
end $$;
revoke all on function public.room_set_judge(text, text) from public, anon;
grant execute on function public.room_set_judge(text, text) to authenticated;

create function public.judge_claim(p_code text) returns jsonb language plpgsql security definer set search_path = '' as $$
declare eng text; s jsonb; sec jsonb; msgs jsonb;
begin
  select engine, state into eng, s from public.rooms where code = p_code for update;
  if s is null or s ->> 'phase' <> 'judging' then return null; end if;
  if (s ->> 'judgeClaimedAt') is not null and gh_private.ms() - (s ->> 'judgeClaimedAt')::bigint < 30000 then return null; end if;
  s := jsonb_set(s, '{judgeClaimedAt}', to_jsonb(gh_private.ms()));
  perform gh_private.save(p_code, s);
  select payload into sec from gh_private.room_secret where room_code = p_code and gid = s ->> 'gid';
  select coalesce(jsonb_agg(jsonb_build_object('team', m.team, 'speaker', m.name, 'kind', m.kind, 'text', coalesce(m.ref, m.text)) order by m.id), '[]'::jsonb) into msgs
  from (select * from public.room_messages x where x.room_code = p_code and x.gid = s ->> 'gid' and x.round = coalesce((s ->> 'round')::int, 1)
          and x.kind in ('msg', 'offer', 'accept') order by x.id desc limit 150) m;
  return jsonb_build_object('engine', eng, 'judgeKey', s ->> 'judgeKey', 'laws', s -> 'laws', 'deal', s -> 'deal',
    'briefs', case when eng = 'deal' then sec -> 'briefs' end, 'transcript', msgs,
    'teamNames', jsonb_build_object('A', gh_private.team_name(eng, s, 'A'), 'B', gh_private.team_name(eng, s, 'B')));
end $$;

create function public.judge_apply(p_code text, p_key text, p_verdict jsonb) returns void language plpgsql security definer set search_path = '' as $$
declare eng text; s jsonb; w text; bonus text; awards jsonb := '{}'::jsonb; k text; t text; res jsonb; sec jsonb;
begin
  select engine, state into eng, s from public.rooms where code = p_code for update;
  if s is null or s ->> 'phase' <> 'judging' or s ->> 'judgeKey' is distinct from p_key then return; end if;
  if p_verdict is null then
    perform gh_private.open_vote(p_code, eng, s, 'The judge couldn''t reach a verdict, so the room decides. Vote now.', 60000);
    return;
  end if;
  w := p_verdict ->> 'winner'; if w is null or w not in ('A', 'B', 'tie') then w := 'tie'; end if;
  bonus := p_verdict ->> 'bonus'; if bonus is not null and bonus not in ('A', 'B') then bonus := null; end if;
  for k, t in select key, value #>> '{}' from jsonb_each(coalesce(s -> 'teams', '{}'::jsonb)) loop
    awards := awards || jsonb_build_object(k, (case when w = 'tie' then 1 when t = w then 3 else 0 end) + (case when t = bonus then 1 else 0 end));
  end loop;
  res := jsonb_build_object('ai', true, 'winner', w, 'awards', awards, 'scores', p_verdict -> 'scores',
    'verdict', left(coalesce(p_verdict ->> 'verdict', ''), 600));
  if eng = 'deal' then
    select payload into sec from gh_private.room_secret where room_code = p_code;
    res := res || jsonb_build_object('briefs', sec -> 'briefs', 'outcome',
      case when s -> 'deal' ->> 'accepted' is not null then 'Deal signed: "' || (s -> 'deal' ->> 'accepted') || '"' else 'No deal. Both sides walked away.' end);
  end if;
  s := gh_private.add_awards(p_code, s, awards) || jsonb_build_object('phase', 'result', 'result', res);
  perform gh_private.save(p_code, s);
end $$;
revoke all on function public.judge_claim(text), public.judge_apply(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.judge_claim(text), public.judge_apply(text, text, jsonb) to service_role;
