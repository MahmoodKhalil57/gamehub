-- GameHub — run this once in the Supabase SQL editor (Dashboard → SQL → New query).
create extension if not exists pgcrypto;

-- Each row is one game, owned by the developer (a Supabase Auth user).
create table if not exists public.games (
  id          uuid primary key default gen_random_uuid(),
  owner       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  slug        text unique not null,
  title       text not null,
  tagline     text not null default '',
  description text not null default '',
  status      text not null default 'draft',          -- draft | published
  config      jsonb not null default '{}'::jsonb,       -- per-game settings (future)
  plays       integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists games_owner_idx  on public.games(owner);
create index if not exists games_status_idx on public.games(status);

-- Row-Level Security IS the backend: these policies are enforced by Postgres itself.
alter table public.games enable row level security;

create policy games_read_published on public.games
  for select using (status = 'published');

create policy games_read_own on public.games
  for select using (owner = (select auth.uid()));

create policy games_insert_own on public.games
  for insert with check (owner = (select auth.uid()));

create policy games_update_own on public.games
  for update using (owner = (select auth.uid())) with check (owner = (select auth.uid()));

create policy games_delete_own on public.games
  for delete using (owner = (select auth.uid()));

-- Count a play without exposing update rights on the whole row.
create or replace function public.increment_play(game_slug text)
returns void language sql security definer set search_path = public as $$
  update public.games set plays = plays + 1 where slug = game_slug and status = 'published';
$$;
grant execute on function public.increment_play(text) to anon, authenticated;
