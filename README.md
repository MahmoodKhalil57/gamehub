# GameHub

A tiny platform for party games. Pure static frontend (HTML/JS/CSS) + Supabase
(Postgres + Auth + Realtime + Row-Level Security). No build step, no app server.

## One-time setup
1. Create a free Supabase project (no card) at supabase.com.
2. SQL editor → paste and run `supabase/schema.sql`.
3. Project Settings → API → copy the Project URL and the `anon` public key into `public/config.js`.
4. Serve the `public/` folder from any static host (Supabase Storage public bucket,
   Cloudflare Pages, Netlify, or `python3 -m http.server` locally). Open it.

## What works now (platform skeleton)
- Developer sign up / log in (Supabase Auth).
- Create / edit / publish / delete your own games (enforced by RLS).
- Public marketplace listing published games + per-game detail page with play counter.

## Next
- The live multiplayer runtime (lobby, realtime chat, crowd-vote scoring) mounts on the
  game detail page, reading each game's `config`. Then: per-developer resource limits and Stripe overages.
