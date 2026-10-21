-- Server-authoritative game engine (applied as migrations secure_rooms_structure, secure_rooms_helpers,
-- secure_rooms_engines, secure_rooms_rpcs, voters_are_participants). Requires rooms.sql first.

----------------------------------------------------------------------------- structure
create schema if not exists gh_private;
revoke all on schema gh_private from public, anon, authenticated;

create table gh_private.content (kind text not null, idx int not null, data jsonb not null, primary key (kind, idx));
create table gh_private.room_secret (room_code text primary key references public.rooms(code) on delete cascade, gid text not null, payload jsonb not null default '{}'::jsonb);
create table gh_private.votes (room_code text not null references public.rooms(code) on delete cascade, vote_key text not null, uid uuid not null, value text not null, primary key (room_code, vote_key, uid));
create table gh_private.accusations (room_code text not null references public.rooms(code) on delete cascade, gid text not null, uid uuid not null, target text not null, primary key (room_code, gid, uid));

alter table public.room_players add column last_seen timestamptz not null default now();
alter table public.room_messages add column seat text;
alter table public.room_messages alter column uid drop not null;
alter table public.room_messages alter column uid drop default;
create index room_messages_seat_idx on public.room_messages(room_code, gid, seat);
create index rooms_host_created_idx on public.rooms(host, created_at);

create table public.room_private (
  room_code text not null references public.rooms(code) on delete cascade,
  uid uuid not null,
  gid text not null,
  payload jsonb not null default '{}'::jsonb,
  primary key (room_code, uid)
);
alter table public.room_private enable row level security;
create policy private_read_own on public.room_private for select to authenticated using (uid = (select auth.uid()));

-- Clients only read these tables; every write goes through the room_* functions.
revoke insert, update, delete on public.rooms, public.room_players, public.room_messages, public.room_private from anon, authenticated;
revoke select on public.rooms, public.room_players, public.room_messages, public.room_private from anon;

-- Guests (anonymous sign-ins) can play but can't create, edit or delete marketplace games.
create policy games_no_guest_insert on public.games as restrictive for insert to authenticated
  with check (coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false);
create policy games_no_guest_update on public.games as restrictive for update to authenticated
  using (coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false);
create policy games_no_guest_delete on public.games as restrictive for delete to authenticated
  using (coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) = false);

-- Plays are counted when a room starts a game, not by page views.
revoke execute on function public.increment_play(text) from public, anon, authenticated;

alter publication supabase_realtime add table public.room_private;

----------------------------------------------------------------------------- helpers
create function gh_private.ms() returns bigint language sql volatile set search_path = '' as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint $$;

create function gh_private.rid() returns text language sql volatile set search_path = '' as $$
  select substr(md5(random()::text || clock_timestamp()::text), 1, 12) $$;

create function gh_private.active(p_code text) returns uuid[] language sql stable set search_path = '' as $$
  select coalesce(array_agg(uid order by joined_at), '{}'::uuid[]) from public.room_players
  where room_code = p_code and last_seen > now() - interval '30 seconds' $$;

create function gh_private.require_player(p_code text) returns uuid language plpgsql stable set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from public.room_players where room_code = p_code and uid = u) then raise exception 'Join the room first.'; end if;
  return u;
end $$;

create function gh_private.save(p_code text, p_state jsonb) returns void language sql set search_path = '' as $$
  update public.rooms set state = p_state, updated_at = now() where code = p_code $$;

create function gh_private.say(p_code text, p_state jsonb, p_kind text, p_text text) returns void language sql set search_path = '' as $$
  insert into public.room_messages (room_code, gid, round, kind, text)
  values (p_code, p_state ->> 'gid', coalesce((p_state ->> 'round')::int, 1), p_kind, left(p_text, 600)) $$;

create function gh_private.pick(p_kind text) returns jsonb language sql volatile set search_path = '' as $$
  select data from gh_private.content where kind = p_kind order by random() limit 1 $$;

create function gh_private.team_name(p_engine text, p_state jsonb, p_team text) returns text language sql immutable set search_path = '' as $$
  select case when p_engine = 'laws' then case when p_state -> 'laws' -> 'sides' ->> p_team = 'for' then 'Keep it' else 'Strike it' end
              when p_engine = 'deal' then coalesce(p_state -> 'deal' -> 'names' ->> p_team, 'Team ' || p_team)
              else p_team end $$;

create function gh_private.with_names(p_code text, p_state jsonb, p_uids uuid[]) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_set(p_state, '{names}', coalesce(p_state -> 'names', '{}'::jsonb) || coalesce(
    (select jsonb_object_agg(uid::text, name) from public.room_players where room_code = p_code and uid = any (p_uids)), '{}'::jsonb)) $$;

create function gh_private.assign_teams(p_state jsonb, p_uids uuid[]) returns jsonb language plpgsql volatile set search_path = '' as $$
declare t jsonb := coalesce(p_state -> 'teams', '{}'::jsonb); a int; b int; u uuid;
begin
  select count(*) filter (where value = '"A"'::jsonb), count(*) filter (where value = '"B"'::jsonb) into a, b from jsonb_each(t);
  for u in select x from unnest(p_uids) as x order by random() loop
    continue when t ? u::text;
    if a <= b then t := t || jsonb_build_object(u::text, 'A'); a := a + 1;
    else t := t || jsonb_build_object(u::text, 'B'); b := b + 1; end if;
  end loop;
  return t;
end $$;

-- Per-player secrets for the current game; the seat is an opaque per-game id stamped on that player's messages.
create function gh_private.set_private(p_code text, p_uid uuid, p_gid text, p_payload jsonb) returns void language sql set search_path = '' as $$
  insert into public.room_private (room_code, uid, gid, payload)
  values (p_code, p_uid, p_gid, jsonb_build_object('seat', gh_private.rid()) || p_payload)
  on conflict (room_code, uid) do update set gid = excluded.gid,
    payload = case when public.room_private.gid = excluded.gid then public.room_private.payload || (excluded.payload - 'seat') else excluded.payload end $$;

create function gh_private.add_awards(p_code text, p_state jsonb, p_awards jsonb) returns jsonb language plpgsql stable set search_path = '' as $$
declare b jsonb := coalesce(p_state -> 'board', '{}'::jsonb); k text; v jsonb;
begin
  for k, v in select key, value from jsonb_each(p_awards) loop
    b := b || jsonb_build_object(k, coalesce((b ->> k)::int, 0) + (v #>> '{}')::int);
  end loop;
  return gh_private.with_names(p_code, jsonb_set(p_state, '{board}', b), array(select key::uuid from jsonb_each(p_awards)));
end $$;

create function gh_private.open_vote(p_code text, p_engine text, p_state jsonb, p_msg text, p_ms int) returns void language plpgsql set search_path = '' as $$
declare s jsonb := p_state; v jsonb; now_ms bigint := gh_private.ms();
begin
  -- Everyone taking part in the round can vote, even if their phone was backgrounded when the vote opened.
  if p_engine = 'friends' then v := coalesce(p_state -> 'tf' -> 'players', '[]'::jsonb);
  else v := coalesce((select jsonb_agg(key) from jsonb_each(coalesce(p_state -> 'teams', '{}'::jsonb))), '[]'::jsonb); end if;
  s := s || jsonb_build_object('phase', 'vote', 'voteKey', gh_private.rid(), 'voteCount', 0, 'voters', v, 'phaseAt', now_ms, 'endsAt', now_ms + p_ms);
  perform gh_private.save(p_code, s);
  perform gh_private.say(p_code, s, 'sys', p_msg);
end $$;

----------------------------------------------------------------------------- engines
create function gh_private.laws_round(p_code text, p_state jsonb, p_first boolean) returns void language plpgsql set search_path = '' as $$
declare s jsonb := p_state; used jsonb := coalesce(p_state -> 'usedLaws', '[]'::jsonb); li int; law jsonb; twist text;
  sides jsonb; act uuid[] := gh_private.active(p_code); now_ms bigint := gh_private.ms(); v_gid text; u uuid;
begin
  select idx, data into li, law from gh_private.content where kind = 'law' and not (used @> to_jsonb(idx)) order by random() limit 1;
  if law is null then
    select idx, data into li, law from gh_private.content where kind = 'law' order by random() limit 1;
    used := '[]'::jsonb;
  end if;
  if random() < 0.35 then twist := gh_private.pick('twist') #>> '{}'; end if;
  if p_first then
    sides := '{"A":"for","B":"against"}'::jsonb;
    v_gid := gh_private.rid();
    s := s || jsonb_build_object('gid', v_gid, 'round', 1, 'teams', gh_private.assign_teams('{}'::jsonb, act));
  else
    sides := jsonb_build_object('A', case when s -> 'laws' -> 'sides' ->> 'A' = 'for' then 'against' else 'for' end,
                                'B', case when s -> 'laws' -> 'sides' ->> 'B' = 'for' then 'against' else 'for' end);
    v_gid := s ->> 'gid';
    s := s || jsonb_build_object('round', coalesce((s ->> 'round')::int, 1) + 1, 'teams', gh_private.assign_teams(s, act));
  end if;
  s := s || jsonb_build_object('phase', 'argue', 'phaseAt', now_ms, 'endsAt', now_ms + coalesce((s ->> 'duration')::int, 180000),
    'laws', jsonb_build_object('law', law ->> 0, 'place', law ->> 1, 'sides', sides, 'twist', twist),
    'usedLaws', used || to_jsonb(li), 'result', null, 'voteKey', null, 'voteCount', 0, 'voters', '[]'::jsonb);
  s := gh_private.with_names(p_code, s, act);
  perform gh_private.save(p_code, s);
  foreach u in array act loop perform gh_private.set_private(p_code, u, v_gid, '{}'::jsonb); end loop;
  perform gh_private.say(p_code, s, 'judge', format('Order in the court. Team "%s" argues to keep this law; team "%s" argues to strike it. Best case wins the room.',
    gh_private.team_name('laws', s, 'A'), gh_private.team_name('laws', s, 'B')) || coalesce(E'\n' || twist, ''));
end $$;

create function gh_private.tf_start(p_code text, p_state jsonb) returns void language plpgsql set search_path = '' as $$
declare s jsonb := p_state; act uuid[]; al text[]; amap jsonb := '{}'::jsonb; v_gid text := gh_private.rid();
  now_ms bigint := gh_private.ms(); i int; n int; sv uuid; su uuid;
begin
  act := array(select x from unnest(gh_private.active(p_code)) x order by random());
  n := cardinality(act);
  if n < 3 then raise exception 'True Friends needs at least 3 players in the room.'; end if;
  al := array(select data #>> '{}' from gh_private.content where kind = 'alias' order by random());
  for i in 1..n loop
    amap := amap || jsonb_build_object(act[i]::text, al[1 + (i - 1) % cardinality(al)] || case when i > cardinality(al) then ' ' || i else '' end);
  end loop;
  sv := act[1]; su := act[2];
  insert into gh_private.room_secret (room_code, gid, payload) values (p_code, v_gid, jsonb_build_object('sv', sv, 'su', su, 'alias', amap))
    on conflict (room_code) do update set gid = excluded.gid, payload = excluded.payload;
  for i in 1..n loop
    perform gh_private.set_private(p_code, act[i], v_gid, jsonb_build_object('alias', amap ->> act[i]::text,
      'role', case when act[i] = sv then 'saviour' else 'player' end,
      'survivor', case when act[i] = sv then amap ->> su::text end));
  end loop;
  -- players and aliases are each shuffled independently so list order leaks nothing about roles or identities
  s := gh_private.with_names(p_code, s, act) || jsonb_build_object('phase', 'chat', 'gid', v_gid, 'round', 1, 'teams', '{}'::jsonb,
    'phaseAt', now_ms, 'endsAt', now_ms + coalesce((s ->> 'duration')::int, 300000),
    'tf', jsonb_build_object('players', (select jsonb_agg(x order by random()) from unnest(act) x),
                             'aliases', (select jsonb_agg(v order by random()) from jsonb_each_text(amap) as e(k, v)), 'cap', 12, 'hint', false),
    'result', null, 'voteKey', null, 'voteCount', 0, 'voters', '[]'::jsonb);
  perform gh_private.save(p_code, s);
  perform gh_private.say(p_code, s, 'judge', E'Welcome, strangers. One of you is a secret Saviour. One of you is quietly being hunted as a friend. Trust carefully.\n\nFirst question: '
    || (gh_private.pick('tf_starter') #>> '{}'));
end $$;

create function gh_private.deal_start(p_code text, p_state jsonb) returns void language plpgsql set search_path = '' as $$
declare s jsonb := p_state; d jsonb := gh_private.pick('deal'); act uuid[] := gh_private.active(p_code);
  v_gid text := gh_private.rid(); now_ms bigint := gh_private.ms(); teams jsonb; u uuid;
begin
  teams := gh_private.assign_teams('{}'::jsonb, act);
  insert into gh_private.room_secret (room_code, gid, payload) values (p_code, v_gid, jsonb_build_object('briefs', jsonb_build_object('A', d -> 'A', 'B', d -> 'B')))
    on conflict (room_code) do update set gid = excluded.gid, payload = excluded.payload;
  s := gh_private.with_names(p_code, s, act) || jsonb_build_object('phase', 'negotiate', 'gid', v_gid, 'round', 1, 'teams', teams,
    'phaseAt', now_ms, 'endsAt', now_ms + coalesce((s ->> 'duration')::int, 360000),
    'deal', jsonb_build_object('title', d ->> 'title', 'setup', d ->> 'setup', 'terms', d -> 'terms',
      'names', jsonb_build_object('A', d -> 'A' ->> 'name', 'B', d -> 'B' ->> 'name'), 'event', false, 'accepted', null),
    'result', null, 'voteKey', null, 'voteCount', 0, 'voters', '[]'::jsonb);
  perform gh_private.save(p_code, s);
  foreach u in array act loop
    perform gh_private.set_private(p_code, u, v_gid, jsonb_build_object('team', teams ->> u::text, 'brief', d -> (teams ->> u::text)));
  end loop;
  perform gh_private.say(p_code, s, 'judge', format(E'%s\n\n%s\n\nOn the table: %s. Read your team''s secret brief. Four formal offers each. Begin.',
    d ->> 'title', d ->> 'setup', (select string_agg(x, ' · ') from jsonb_array_elements_text(d -> 'terms') x)));
end $$;

create function gh_private.finish(p_code text, p_engine text, p_state jsonb) returns void language plpgsql set search_path = '' as $$
declare s jsonb := p_state; ca int; cb int; w text; awards jsonb := '{}'::jsonb; k text; t text; res jsonb; sec jsonb;
  amap jsonb; inv jsonb; sv text; su text; picked jsonb := '{}'::jsonb; p text; pick_alias text; survivor_picked boolean; r record;
begin
  if p_engine = 'friends' then
    select payload into sec from gh_private.room_secret where room_code = p_code;
    amap := sec -> 'alias'; sv := sec ->> 'sv'; su := sec ->> 'su';
    select jsonb_object_agg(value #>> '{}', key) into inv from jsonb_each(amap);
    for p in select jsonb_array_elements_text(s -> 'tf' -> 'players') loop
      awards := awards || jsonb_build_object(p, 0);
      select value into pick_alias from gh_private.votes where room_code = p_code and vote_key = s ->> 'voteKey' and uid = p::uuid;
      picked := picked || jsonb_build_object(p, inv ->> pick_alias);
    end loop;
    survivor_picked := coalesce((picked ->> su) = sv, false);
    if survivor_picked then
      awards := awards || jsonb_build_object(sv, (awards ->> sv)::int + 5, su, (awards ->> su)::int + 2);
    end if;
    for p in select jsonb_array_elements_text(s -> 'tf' -> 'players') loop
      continue when p = sv or p = su;
      if (picked ->> p) = sv then awards := jsonb_set(awards, array[p], to_jsonb((awards ->> p)::int + 2));
      else awards := jsonb_set(awards, array[sv], to_jsonb((awards ->> sv)::int + 1)); end if;
    end loop;
    for r in select a.uid::text as u, a.target from gh_private.accusations a where a.room_code = p_code and a.gid = s ->> 'gid' loop
      continue when r.u = sv or not (awards ? r.u);
      awards := jsonb_set(awards, array[r.u], to_jsonb((awards ->> r.u)::int + case when (inv ->> r.target) = sv then 2 else -1 end));
    end loop;
    res := jsonb_build_object('awards', awards, 'survivorPicked', survivor_picked, 'picked', picked, 'sv', sv, 'su', su, 'alias', amap,
      'verdict', case when survivor_picked then format('The Saviour pulled it off. %s picked %s.', amap ->> su, amap ->> sv)
                      else format('The Survivor didn''t fall for it. %s did not pick the Saviour, %s.', amap ->> su, amap ->> sv) end);
    s := gh_private.add_awards(p_code, s, awards) || jsonb_build_object('phase', 'reveal', 'result', res);
  else
    select count(*) filter (where value = 'A'), count(*) filter (where value = 'B') into ca, cb
      from gh_private.votes where room_code = p_code and vote_key = s ->> 'voteKey';
    w := case when ca = cb then 'tie' when ca > cb then 'A' else 'B' end;
    for k, t in select key, value #>> '{}' from jsonb_each(coalesce(s -> 'teams', '{}'::jsonb)) loop
      awards := awards || jsonb_build_object(k, case when w = 'tie' then 1 when t = w then 3 else 0 end);
    end loop;
    res := jsonb_build_object('counts', jsonb_build_object('A', ca, 'B', cb), 'winner', w, 'awards', awards,
      'verdict', case when w = 'tie' then 'The room is split down the middle. Dead heat.'
                      else format('The room sided with "%s" %s–%s.', gh_private.team_name(p_engine, s, w), greatest(ca, cb), least(ca, cb)) end);
    if p_engine = 'deal' then
      select payload into sec from gh_private.room_secret where room_code = p_code;
      res := res || jsonb_build_object('briefs', sec -> 'briefs', 'outcome',
        case when s -> 'deal' ->> 'accepted' is not null then 'Deal signed: "' || (s -> 'deal' ->> 'accepted') || '"' else 'No deal. Both sides walked away.' end);
    end if;
    s := gh_private.add_awards(p_code, s, awards) || jsonb_build_object('phase', 'result', 'result', res);
  end if;
  perform gh_private.save(p_code, s);
end $$;

----------------------------------------------------------------------------- functions players call
create function public.create_room(p_slug text) returns text language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); eng text; v_code text; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  if u is null then raise exception 'Sign in first.'; end if;
  select config ->> 'engine' into eng from public.games where slug = p_slug and status = 'published';
  if eng is null or eng not in ('laws', 'friends', 'deal') then raise exception 'That game has no live rooms.'; end if;
  if (select count(*) from public.rooms where host = u and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'You''ve created a lot of rooms recently. Try again in a bit.'; end if;
  for i in 1..10 loop
    v_code := (select string_agg(substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1), '') from generate_series(1, 5));
    begin
      insert into public.rooms (code, game_slug, engine, host, state)
      values (v_code, p_slug, eng, u, jsonb_build_object('phase', 'lobby', 'gid', gh_private.rid(), 'round', 1, 'board', '{}'::jsonb, 'names', '{}'::jsonb));
      return v_code;
    exception when unique_violation then null;
    end;
  end loop;
  raise exception 'Couldn''t find a free room code. Try again.';
end $$;

create function public.join_room(p_code text, p_name text, p_color text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); n text := btrim(coalesce(p_name, '')); c text := p_color;
begin
  if u is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from public.rooms where code = p_code) then raise exception 'That room doesn''t exist.'; end if;
  if char_length(n) < 1 or char_length(n) > 24 then raise exception 'Names must be 1–24 characters.'; end if;
  if c is null or c !~ '^#[0-9a-fA-F]{6}$' then c := '#6c5ce7'; end if;
  if not exists (select 1 from public.room_players where room_code = p_code and uid = u)
     and (select count(*) from public.room_players where room_code = p_code) >= 40 then
    raise exception 'This room is full.'; end if;
  insert into public.room_players (room_code, uid, name, color, last_seen) values (p_code, u, n, c, now())
  on conflict (room_code, uid) do update set name = excluded.name, color = excluded.color, last_seen = now();
end $$;

-- Any player's page calls this every few seconds. It is the room's clock: it only advances a phase once its time has really passed.
create function public.room_tick(p_code text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); eng text; s jsonb; ph text; now_ms bigint := gh_private.ms(); missing uuid[]; x uuid; sec jsonb;
begin
  update public.room_players set last_seen = now() where room_code = p_code and uid = u and last_seen < now() - interval '10 seconds';
  select engine, state into eng, s from public.rooms where code = p_code for update;
  ph := s ->> 'phase';
  if eng in ('laws', 'deal') and ph in ('argue', 'negotiate') then
    missing := array(select y from unnest(gh_private.active(p_code)) y where not (coalesce(s -> 'teams', '{}'::jsonb) ? y::text));
    if cardinality(missing) > 0 then
      s := gh_private.with_names(p_code, s || jsonb_build_object('teams', gh_private.assign_teams(s, missing)), missing);
      perform gh_private.save(p_code, s);
      select payload into sec from gh_private.room_secret where room_code = p_code;
      foreach x in array missing loop
        perform gh_private.set_private(p_code, x, s ->> 'gid', case when eng = 'deal'
          then jsonb_build_object('team', s -> 'teams' ->> x::text, 'brief', sec -> 'briefs' -> (s -> 'teams' ->> x::text)) else '{}'::jsonb end);
      end loop;
    end if;
  end if;
  if ph = 'vote' then
    if now_ms >= (s ->> 'endsAt')::bigint or (s ->> 'voteCount')::int >= jsonb_array_length(s -> 'voters') then
      perform gh_private.finish(p_code, eng, s);
    end if;
    return;
  end if;
  if ph in ('argue', 'chat', 'negotiate') and now_ms >= (s ->> 'endsAt')::bigint then
    perform gh_private.open_vote(p_code, eng, s,
      case eng when 'laws' then 'Time! Vote for the side that argued best.'
               when 'friends' then 'Chat closed. Pick your true friend.'
               else 'Time! No deal signed. Vote for the side that negotiated best.' end,
      case eng when 'friends' then 75000 else 60000 end);
    return;
  end if;
  if eng = 'friends' and ph = 'chat' and not coalesce((s -> 'tf' ->> 'hint')::boolean, false)
     and now_ms >= (s ->> 'phaseAt')::bigint + ((s ->> 'endsAt')::bigint - (s ->> 'phaseAt')::bigint) / 2 then
    s := jsonb_set(s, '{tf,hint}', 'true'::jsonb);
    perform gh_private.save(p_code, s);
    perform gh_private.say(p_code, s, 'judge', 'Halfway hint: ' || (gh_private.pick('tf_hint') #>> '{}'));
  end if;
  if eng = 'deal' and ph = 'negotiate' and not coalesce((s -> 'deal' ->> 'event')::boolean, false)
     and now_ms >= (s ->> 'phaseAt')::bigint + ((s ->> 'endsAt')::bigint - (s ->> 'phaseAt')::bigint) / 2 then
    s := jsonb_set(s, '{deal,event}', 'true'::jsonb);
    perform gh_private.save(p_code, s);
    perform gh_private.say(p_code, s, 'judge', 'Breaking news: ' || (gh_private.pick('deal_event') #>> '{}'));
  end if;
end $$;

create function public.room_vote(p_code text, p_value text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); eng text; s jsonb; mine text; n int;
begin
  select engine, state into eng, s from public.rooms where code = p_code for update;
  if s ->> 'phase' <> 'vote' then raise exception 'Voting is closed.'; end if;
  if not (s -> 'voters' ? u::text) then raise exception 'You''re watching this round.'; end if;
  if eng = 'friends' then
    select payload ->> 'alias' into mine from public.room_private where room_code = p_code and uid = u and gid = s ->> 'gid';
    if not (s -> 'tf' -> 'aliases' ? p_value) or p_value = mine then raise exception 'Pick someone else.'; end if;
  elsif p_value is null or p_value not in ('A', 'B') then raise exception 'Pick a side.';
  end if;
  insert into gh_private.votes (room_code, vote_key, uid, value) values (p_code, s ->> 'voteKey', u, p_value)
  on conflict (room_code, vote_key, uid) do update set value = excluded.value;
  select count(*) into n from gh_private.votes where room_code = p_code and vote_key = s ->> 'voteKey';
  s := jsonb_set(s, '{voteCount}', to_jsonb(n));
  if n >= jsonb_array_length(s -> 'voters') then perform gh_private.finish(p_code, eng, s);
  else perform gh_private.save(p_code, s); end if;
end $$;

create function public.room_post(p_code text, p_kind text, p_text text default '', p_target text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); eng text; s jsonb; ph text; v_gid text; priv jsonb; v_seat text; v_team text; v_name text;
  txt text := btrim(coalesce(p_text, '')); v_offer text;
begin
  select engine, state into eng, s from public.rooms where code = p_code for update;
  ph := s ->> 'phase'; v_gid := s ->> 'gid';
  select payload into priv from public.room_private where room_code = p_code and uid = u and gid = v_gid;
  v_seat := priv ->> 'seat'; v_team := s -> 'teams' ->> u::text;
  select name into v_name from public.room_players where room_code = p_code and uid = u;
  if p_kind is null or p_kind not in ('msg', 'offer', 'accept', 'accuse') then raise exception 'Unknown action.'; end if;
  if p_kind in ('msg', 'offer') and (char_length(txt) < 1 or char_length(txt) > 280) then raise exception 'Messages must be 1–280 characters.'; end if;
  if v_seat is null then raise exception 'You''re watching this game.'; end if;
  if (select count(*) from public.room_messages m where m.room_code = p_code and m.seat = v_seat and m.created_at > now() - interval '4 seconds') >= 3 then
    raise exception 'Slow down a little.'; end if;

  if eng = 'laws' then
    if ph <> 'argue' or v_team is null or p_kind <> 'msg' then raise exception 'You can''t speak right now.'; end if;
    insert into public.room_messages (room_code, gid, round, kind, name, team, seat, text)
    values (p_code, v_gid, coalesce((s ->> 'round')::int, 1), 'msg', v_name, v_team, v_seat, txt);

  elsif eng = 'deal' then
    if ph <> 'negotiate' or v_team is null or p_kind = 'accuse' then raise exception 'You can''t do that right now.'; end if;
    if p_kind = 'offer' and (select count(*) from public.room_messages m
        where m.room_code = p_code and m.gid = v_gid and m.kind = 'offer' and m.team = v_team) >= 4 then
      raise exception 'Your team has no formal offers left.'; end if;
    if p_kind = 'accept' then
      select m.text into v_offer from public.room_messages m
      where m.room_code = p_code and m.gid = v_gid and m.kind = 'offer' and m.team <> v_team order by m.id desc limit 1;
      if v_offer is null then raise exception 'There''s no offer to accept.'; end if;
      insert into public.room_messages (room_code, gid, round, kind, name, team, seat, text, ref)
      values (p_code, v_gid, 1, 'accept', v_name, v_team, v_seat, 'Accepted', v_offer);
      s := jsonb_set(s, '{deal,accepted}', to_jsonb(v_offer));
      perform gh_private.open_vote(p_code, eng, s, 'A deal was accepted! Vote for the side that got the better end.', 60000);
      return;
    end if;
    insert into public.room_messages (room_code, gid, round, kind, name, team, seat, text)
    values (p_code, v_gid, 1, p_kind, v_name, v_team, v_seat, txt);

  else
    if ph <> 'chat' or not (s -> 'tf' -> 'players' ? u::text) then raise exception 'You can''t speak right now.'; end if;
    if p_kind = 'msg' then
      if (select count(*) from public.room_messages m where m.room_code = p_code and m.gid = v_gid and m.seat = v_seat and m.kind = 'msg')
         >= coalesce((s -> 'tf' ->> 'cap')::int, 12) then raise exception 'You''ve used all your messages.'; end if;
      insert into public.room_messages (room_code, gid, round, kind, alias, seat, text)
      values (p_code, v_gid, 1, 'msg', priv ->> 'alias', v_seat, txt);
    elsif p_kind = 'accuse' then
      if p_target is null or not (s -> 'tf' -> 'aliases' ? p_target) or p_target = priv ->> 'alias' then raise exception 'Pick someone else.'; end if;
      if exists (select 1 from gh_private.accusations a where a.room_code = p_code and a.gid = v_gid and a.uid = u) then
        raise exception 'You''ve already accused someone.'; end if;
      insert into gh_private.accusations (room_code, gid, uid, target) values (p_code, v_gid, u, p_target);
      insert into public.room_messages (room_code, gid, round, kind, alias, seat) values (p_code, v_gid, 1, 'accuse', priv ->> 'alias', v_seat);
    else
      raise exception 'You can''t do that in this game.';
    end if;
  end if;
end $$;

create function public.room_start(p_code text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); eng text; s jsonb; h uuid; v_slug text; need int;
begin
  select engine, state, host, game_slug into eng, s, h, v_slug from public.rooms where code = p_code for update;
  if h <> u then raise exception 'Only the host can start the game.'; end if;
  if coalesce(s ->> 'phase', 'lobby') not in ('lobby', 'result', 'reveal') then raise exception 'A game is already running.'; end if;
  update public.room_players set last_seen = now() where room_code = p_code and uid = u;
  need := case eng when 'friends' then 3 else 2 end;
  if cardinality(gh_private.active(p_code)) < need then raise exception 'This game needs at least % players in the room.', need; end if;
  update public.games set plays = plays + 1 where slug = v_slug;
  if eng = 'laws' then perform gh_private.laws_round(p_code, s, true);
  elsif eng = 'friends' then perform gh_private.tf_start(p_code, s);
  else perform gh_private.deal_start(p_code, s); end if;
end $$;

create function public.room_next_round(p_code text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); eng text; s jsonb; h uuid;
begin
  select engine, state, host into eng, s, h from public.rooms where code = p_code for update;
  if h <> u then raise exception 'Only the host can do that.'; end if;
  if eng <> 'laws' or s ->> 'phase' <> 'result' then raise exception 'There''s no round to continue.'; end if;
  perform gh_private.laws_round(p_code, s, false);
end $$;

create function public.room_to_lobby(p_code text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); s jsonb; h uuid;
begin
  select state, host into s, h from public.rooms where code = p_code for update;
  if h <> u then raise exception 'Only the host can do that.'; end if;
  perform gh_private.save(p_code, s || jsonb_build_object('phase', 'lobby', 'voteKey', null));
end $$;

create function public.room_set_duration(p_code text, p_ms int) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); eng text; s jsonb; h uuid;
begin
  select engine, state, host into eng, s, h from public.rooms where code = p_code for update;
  if h <> u then raise exception 'Only the host can do that.'; end if;
  if coalesce(s ->> 'phase', 'lobby') <> 'lobby' then raise exception 'Change the round length in the lobby.'; end if;
  if not (p_ms = any (case eng when 'laws' then array[120000, 180000, 300000] when 'friends' then array[180000, 300000, 420000]
                               else array[240000, 360000, 480000] end)) then raise exception 'That round length isn''t available.'; end if;
  perform gh_private.save(p_code, jsonb_set(s, '{duration}', to_jsonb(p_ms)));
end $$;

create function public.room_takeover(p_code text) returns void language plpgsql security definer set search_path = '' as $$
declare u uuid := gh_private.require_player(p_code); h uuid;
begin
  select host into h from public.rooms where code = p_code for update;
  if h = u then return; end if;
  if exists (select 1 from public.room_players where room_code = p_code and uid = h and last_seen > now() - interval '25 seconds') then
    raise exception 'The host is still here.'; end if;
  update public.rooms set host = u, updated_at = now() where code = p_code;
end $$;

revoke all on function public.create_room(text), public.join_room(text, text, text), public.room_tick(text), public.room_vote(text, text),
  public.room_post(text, text, text, text), public.room_start(text), public.room_next_round(text), public.room_to_lobby(text),
  public.room_set_duration(text, int), public.room_takeover(text) from public, anon;
grant execute on function public.create_room(text), public.join_room(text, text, text), public.room_tick(text), public.room_vote(text, text),
  public.room_post(text, text, text, text), public.room_start(text), public.room_next_round(text), public.room_to_lobby(text),
  public.room_set_duration(text, int), public.room_takeover(text) to authenticated;
