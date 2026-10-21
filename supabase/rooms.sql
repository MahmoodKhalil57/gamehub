-- Live rooms for the house games (applied to the project as migration `rooms_players_messages`).
alter table public.games alter column owner drop not null;   -- owner null = built-in house game

create table public.rooms (
  code       text primary key check (code ~ '^[A-Z0-9]{5}$'),
  game_slug  text not null references public.games(slug) on delete cascade,
  engine     text not null check (engine in ('laws','friends','deal')),
  host       uuid not null default auth.uid(),
  state      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.room_players (
  room_code text not null references public.rooms(code) on delete cascade,
  uid       uuid not null default auth.uid(),
  name      text not null check (char_length(name) between 1 and 24),
  color     text not null default '#6c5ce7' check (color ~ '^#[0-9a-fA-F]{6}$'),
  vote      text check (char_length(vote) <= 40),
  vote_key  text,
  joined_at timestamptz not null default now(),
  primary key (room_code, uid)
);

create table public.room_messages (
  id         bigint generated always as identity primary key,
  room_code  text not null references public.rooms(code) on delete cascade,
  uid        uuid not null default auth.uid(),
  gid        text not null,
  round      integer not null default 1,
  kind       text not null default 'msg' check (kind in ('msg','sys','judge','offer','accept','accuse')),
  name       text not null default '' check (char_length(name) <= 24),
  alias      text check (char_length(alias) <= 30),
  team       text check (team in ('A','B')),
  text       text not null default '' check (char_length(text) <= 600),
  ref        text check (char_length(ref) <= 600),
  target     text check (char_length(target) <= 30),
  created_at timestamptz not null default now()
);
create index room_messages_room_idx on public.room_messages(room_code, id);
create index room_players_uid_idx on public.room_players(uid);

alter table public.rooms enable row level security;
alter table public.room_players enable row level security;
alter table public.room_messages enable row level security;

-- Players (including anonymous guests, who have the `authenticated` role) can read every room;
-- they can only write as themselves, and only players in a room can change its state.
create policy rooms_read on public.rooms for select to authenticated using (true);
create policy rooms_create on public.rooms for insert to authenticated with check (host = (select auth.uid()));
create policy rooms_update_by_player on public.rooms for update to authenticated
  using (exists (select 1 from public.room_players p where p.room_code = rooms.code and p.uid = (select auth.uid())));

create policy players_read on public.room_players for select to authenticated using (true);
create policy players_join on public.room_players for insert to authenticated with check (uid = (select auth.uid()));
create policy players_update_self on public.room_players for update to authenticated
  using (uid = (select auth.uid())) with check (uid = (select auth.uid()));
create policy players_leave on public.room_players for delete to authenticated using (uid = (select auth.uid()));

create policy messages_read on public.room_messages for select to authenticated using (true);
create policy messages_post on public.room_messages for insert to authenticated
  with check (uid = (select auth.uid())
    and exists (select 1 from public.room_players p where p.room_code = room_messages.room_code and p.uid = (select auth.uid())));

alter publication supabase_realtime add table public.rooms, public.room_players, public.room_messages;

-- House games listed in the marketplace (config.engine picks the runtime in gamehub-ui/play.js).
insert into public.games (owner, slug, title, tagline, status, config) values
  (null, 'dumb-laws',       'Dumb Laws',       'Argue for or against a real (reportedly) dumb law. The room decides who won.', 'published', '{"engine":"laws","min":2}'),
  (null, 'true-friends',    'True Friends',    'Anonymous chat. One secret Saviour must win over one unknowing Survivor.',     'published', '{"engine":"friends","min":3}'),
  (null, 'art-of-the-deal', 'Art of the Deal', 'Two teams, secret briefs, four formal offers. Strike the better deal.',          'published', '{"engine":"deal","min":2}')
on conflict (slug) do nothing;
