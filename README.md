# ex-tales-forge

A few friends and I have been building a text-first RPG on Elixir. Phoenix for the table, Jido for the hot session, Postgres for the save, Oban for the slow thinking.

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

Every page (play and admin) needs "Sign in with GitHub" as an active member of the
`ADMIN_GITHUB_TEAM` GitHub team (`whyse-ab/tales-forge`); there is no other login and no
separate admin check. Locally, set in `.env` a GitHub OAuth app with callback
`http://localhost:4000/admin/auth/github/callback`, the team, and a token that can read the
org's members:

```
GITHUB_OAUTH_CLIENT_ID=...
GITHUB_OAUTH_CLIENT_SECRET=...
ADMIN_GITHUB_TEAM=whyse-ab/tales-forge
GITHUB_DOCS_TOKEN=...
```

Then open http://localhost:4000/ (you are sent to `/admin/login`). See `docs/DEPLOY-FLY.md`.

From the admin UI you can:

- **Decision queue** and **shared docs** (synced from `tales-forge-docs`)
- List and delete game sessions; edit `world_state` JSON
- Inspect and edit per-session NPC runtime state (stock, mood, memories)
- Browse turn history (read-only)
- Edit session fields and NPC disposition (Ecto changeset forms); JSON editors for complex state like `world_state`
- View the authored NPC definitions in `priv/npcs` (read-only; edit the files in git)
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

Who it is for: [PRODUCT.md](PRODUCT.md) (Hawk, Paul, Lotta, Lars — not Ronny). How it runs: [docs/architecture.md](docs/architecture.md). Three slides if we have to explain it at ElixirConf: [docs/elixirconf-2027/README.md](https://github.com/whyse-ab/ex-tales-forge/tree/main/docs/elixirconf-2027).

## Phase status

- [x] Phase 0: Phoenix + Jido + LiveView play loop with mock GM
- [x] Phase 1: Two-tier LLM pipeline + server mechanics (mock GM when no API key)
- [x] Phase 2: pack files for authored content + admin surfaces. (Ash was used here at first and removed on 2026-10-07; admin and play are plain Ecto.)
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