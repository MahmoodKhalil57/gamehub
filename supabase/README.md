# Database

Apply in order on a fresh Supabase project (all of these are already applied to the live project):

1. `schema.sql` — marketplace `games` table and policies.
2. `rooms.sql` — rooms, players and messages tables, house games.
3. `secure_rooms.sql` — server-authoritative game engine: clients only read; every move goes
   through a `room_*` function that checks the rules. Secrets live in `room_private` (each player
   reads only their own row) and the `gh_private` schema (not reachable through the API).
4. `ai_judge.sql` — optional AI judge for Dumb Laws and Art of the Deal (needs the `judge` Edge Function).
5. `content.sql` — laws, aliases, twists, hints, deal scenarios used by the engines.

Guest players use Supabase anonymous sign-ins (Authentication → Sign In / Providers).

## AI judge

`functions/judge` is a Supabase Edge Function that scores rounds with Cloudflare's Clef Flash decision model on OpenRouter.
It needs one secret, `OPENROUTER_API_KEY` (Edge Functions → Secrets). The key never reaches the browser.
