# ex-tales-forge

A few friends and I have been building a text-first RPG on Elixir. Phoenix for the table, Jido for the hot session, Postgres for the save, Oban for the slow thinking.

This is a greenfield rewrite. Rules and prompts come from [text-forge](../text-forge). We did not port the old Supabase code.

## Stack

| Layer | Technology |
|-------|------------|
| UI | Phoenix LiveView |
| Game runtime | Jido 2.x agents + actions |
| Database | PostgreSQL + Ecto |
| Background jobs | Oban |
| LLM | xAI Grok (Tier 1 intent + Tier 2 GM) |
| Images (planned) | Tigris on Fly.io |
| Deploy (planned) | Fly.io |

## Prerequisites

- Elixir 1.15+
- PostgreSQL 16+ (local default: `postgres` / `postgres`)
- Node.js (for asset bundling)

## Local setup

### 1. Environment file

Secrets live in `.env` at the project root. This file is gitignored — only `.env.example` is committed.

```bash
cd ex-tales-forge
cp .env.example .env
```

Edit `.env` and add your xAI API key:

```
XAI_API_KEY=xai-your-key-here
```

The app loads `.env` automatically in development via `config/runtime.exs`. You do not need to `export` variables manually.

### 2. Database

Start PostgreSQL if it is not already running:

```bash
brew services start postgresql@16
```

Create the database and run migrations:

```bash
mix setup
```

To use a non-default connection string, uncomment `DATABASE_URL` in `.env`:

```
DATABASE_URL=ecto://postgres:postgres@localhost/ex_tales_forge_dev
```

### 3. Verify

```bash
mix dev.check
```

You should see PostgreSQL connected and your API key masked (e.g. `xai-...abcd`). If the key is missing, the game falls back to mock GM narration.

## Run

```bash
mix phx.server
```

Open http://localhost:4000

1. Click **Start new session**
2. Type an action on the play screen

With `XAI_API_KEY` set, the play header shows `GM source: api` after your first turn. Without it, you will see `GM source: mock`.

Default model is fast non-reasoning Grok (`grok-4.20-0309-non-reasoning`). Verify turn latency with `mix e2e.smoke` (3s budget per turn).

## Admin console

Open http://localhost:4000/admin/login (email magic link for allowlisted founders; "Sign in with GitHub" appears when `GITHUB_OAUTH_CLIENT_ID`/`GITHUB_OAUTH_CLIENT_SECRET` are set, see `docs/DEPLOY-FLY.md`).

Set allowlist in `.env`:

```
ADMIN_EMAILS=you@example.com,cofounder@example.com
```

In development the magic link appears in the Swoosh mailbox at `/dev/mailbox`.

From the admin UI you can:

- **Decision queue** and **shared docs** (synced from `tales-forge-docs`)
- List and delete game sessions; edit `world_state` JSON
- Inspect and edit per-session NPC runtime state (stock, mood, memories)
- Browse turn history (read-only)
- Edit authored NPC definitions (Ash) and runtime session/NPC state (via Ash admin resources, but play uses Ecto)
- Admin LiveViews use AshPhoenix.Form for simple fields; JSON editors kept for complex state like `world_state`
- Open LiveDashboard at `/admin/oban` for Oban/telemetry

See [docs/DEPLOY-FLY.md](docs/DEPLOY-FLY.md) for Fly.io deploy steps.

## Project layout

```
lib/
  ex_tales_forge/
    agents/          # Jido agents (PlayerSessionAgent, NPC agents later)
    actions/         # Jido actions (PlayerMessage, LLM pipeline later)
    game/            # Pure game logic (mechanics, inventory)
    schemas/         # Ecto schemas (runtime persistence)
    game_sessions.ex # Session + agent coordination
  ex_tales_forge_web/
    live/            # HomeLive, PlayLive
priv/
  rules/             # Markdown rulebook (from text-forge)
```

Who it is for: [PRODUCT.md](PRODUCT.md) (Hawk, Paul, Lotta, Lars — not Ronny). How it runs: [docs/architecture.md](docs/architecture.md). Three slides if we have to explain it at ElixirConf: [docs/elixirconf-2027/README.md](docs/elixirconf-2027/README.md).

## Phase status

- [x] Phase 0: Phoenix + Jido + LiveView play loop with mock GM
- [x] Phase 1: Two-tier LLM pipeline + server mechanics (mock GM when no API key)
- [x] Phase 2: Ash for pre-play authoring + admin surfaces (AshPhoenix.Forms on runtime tables via AdminResources, but **core play paths remain 100% Ecto**). Generic linked-MD pack importer + `mix tales.import_pack`. Materialization and admin LiveViews updated. See plan.
- [ ] Phase 3: NPC agents + world clock

## Development

See [AGENTS.md](AGENTS.md) for git workflow, Elixir idioms, LLM conventions, and troubleshooting.

- Work on feature branches — never commit directly to `main`
- Run `mix format` while coding; run `mix precommit` before opening a PR
- `mix quality` runs format check + Credo on `lib/`
- After gameplay changes, smoke-test with `/play_test` (see `.grok/skills/play-test/SKILL.md`)

## Tests

```bash
mix test
```