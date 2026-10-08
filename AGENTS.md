# ex-tales-forge — Agent Rules

## Project

Text-first AI RPG on the BEAM. Jido agents own play-session runtime; LiveView is the UI; PostgreSQL holds sessions and turn history.

Greenfield Elixir rewrite of text-forge (a separate, earlier app). Borrow rules, prompts, and lore from text-forge; do not port v1 Supabase code.

Who we build for is in [PRODUCT.md](PRODUCT.md). Core table: **Hawk** (hard mode), **Paul** (role-playing, mechanics invisible), **Lotta** (identification, world and character), **Lars** (adventure). **Ronny** (win, loot, highest level) is the anti-persona — do not add systems that exist to let him win.

Rules identity (same file, Rules philosophy): prices ≈ human labor; you learn by failing, slowly, with transfer across related skills. Do not invent XP bars or loot-table gold. Fewer non-intuitive rules → easier to stay in the story.

## Stack

- **UI:** Phoenix LiveView + Tailwind
- **Runtime:** Jido 2.x agents + actions
- **Persistence:** Ecto + PostgreSQL (`GameSession`, `Turn`, `NpcInstance`)
- **Jobs:** Oban (LLM, sim)
- **Authored content:** pack files under `priv/` (`priv/adventures/*`, `priv/npcs/*.json`, `priv/rules`, `priv/prompts`), loaded by `Game.Pack` / `NPC` and copied into each session at creation. Edited in git; the admin NPC definition pages are read-only.
- **Admin:** `TalesForge.Admin` + LiveViews on plain Ecto changesets (`to_form/2`); JSON editors for complex maps like `world_state`. Ash was removed on 2026-10-07 (tales-forge-docs `docs/decisions.md`); revisit only if an in-app adventure editor needs it.

## Non-negotiables

1. Persistence is plain Ecto + Repo everywhere (play loop, Jido, Oban, GameSessions, NPC logic, admin). Authored content lives in pack files, not database tables. Don't add a second data layer without a decision entry.
2. Tier 1 intent must run before Tier 2 GM; raw player text never reaches Tier 2
3. Server rolls dice and applies LP/inventory — the LLM narrates, not invents mechanics
4. Important authored state stays human-readable: `priv/rules/*.md`, `priv/prompts/*.txt`
5. LLM responses use structured JSON (Tier 1 `PlayerAction` via `TalesForge.Game.Intent`)
6. Turn history is auditable — persisted in the `Turn` schema (text-forge uses git commits per campaign turn; same goal, different storage)
7. Borrow rules/prompts/lore from `../text-forge`; do not port v1 Supabase code

## Git workflow

1. **Never commit development work directly to `main`.**
2. Before starting a new feature or fix, create a branch:
   ```bash
   git checkout main
   git pull origin main
   git checkout -b feature/<short-name>
   ```
3. Use kebab-case short names that describe the work (e.g. `feature/two-tier-llm`, `setup/local-env`, `fix/oban-migration`).
4. Commit and push on the feature branch; merge to `main` via PR when ready.
5. If already on `main` with uncommitted work, stash or commit to a new feature branch before continuing.

## Elixir coding guidelines

### Formatting (mandatory)

- Run `mix format` before every commit
- `mix precommit` runs `mix format` then `mix quality` (format check + Credo)
- [.formatter.exs](https://github.com/whyse-ab/ex-tales-forge/blob/main/.formatter.exs) is authoritative (Phoenix, Ecto, LiveView HEEx)

### Docs, types and tests (mandatory)

Humans may need to understand the code one day. The full standard is
`docs/coding-standards.md` in tales-forge-docs; CI enforces it.

- `@moduledoc` on every module (`@moduledoc false` only for internals); Credo checks it.
- `@doc` on every public function (`@doc false` if internal), with a doctest where an
  example helps. `test/ex_tales_forge/coding_standards_test.exs` checks the backfilled modules.
- `@spec` on every public function; Dialyzer (`mix dialyzer`) checks them. Credo
  `Readability.Specs` enforces presence for the backfilled files listed in `.credo.exs`.
- Tests for every change; `mix test --cover` fails below the threshold in `mix.exs`.
- `mix docs` builds the docs site into `doc/`.
- Backfill legacy modules when you touch them, then add them to the lists above.

### Idioms

| Prefer | Over |
|--------|------|
| `\|>` for linear data transforms | nested calls and temp variables |
| `with` for `{:ok, _}` / `{:error, _}` pipelines | nested `case` or deep `if` |
| multiclause functions + pattern matching | long `cond` / `if/else` chains |
| tagged tuples for control flow | bare values or exceptions for expected paths |
| guards in function heads (`when`) | repeated runtime nil checks |

```elixir
# Good: with + tagged tuples
with {:ok, session} <- Repo.insert(changeset),
     :ok <- ensure_agent(session) do
  {:ok, session}
end

# Good: pipe for transforms
extraction
|> ensure_skill(raw_action)
|> validate_player_action(context)

# Good: pattern match in function head
def handle_info({:turn_completed, payload}, socket) do
  ...
end
```

### Project conventions

- **Orchestration** in contexts (`GameSessions`, `TurnProcessor`); Oban workers stay thin
- **Pure game logic** in `TalesForge.Game.*` — no `Repo` in mechanics/intent
- **Config** through `TalesForge.Config` — avoid scattered `System.get_env/1` in lib
- **LLM calls** only in `TalesForge.LLM`
- **Logging:** `require Logger` at module top; include ids and timings (`session=`, `tier=`, `duration_ms=`)
- **Errors:** `{:error, reason}` for expected failures; `raise` for programmer bugs; `rescue` only for domain exceptions (e.g. `Intent.ClarificationNeeded`)

### Anti-patterns

- `if is_nil(x)` when a function clause or `with` handles nil
- Committing without `mix precommit`
- Bypassing format or Credo locally "just this once"

### Quality commands

```bash
mix format          # auto-format
mix format.check    # fail if not formatted (CI-friendly)
mix credo           # lint lib/
mix quality         # format.check + credo --strict
mix precommit       # compile, format, quality, test + coverage, docs, dialyzer — run before PR
mix dialyzer        # type check (first run builds the PLT in priv/plts, a few minutes)
mix test --cover    # tests with coverage summary (HTML in cover/)
mix docs            # docs site in doc/
```

## Dev commands

```bash
cp .env.example .env          # add XAI_API_KEY
mix setup                     # deps, DB, assets
mix dev.check                 # Postgres + API key + provider
mix phx.server                # http://localhost:4000
mix warnings                  # reprint THIS app's compiler warnings; fail if any
mix test
mix precommit                 # format + quality + test (run before opening a PR)
```

### Troubleshooting

**Port 4000 in use** — stale server still running:

```bash
lsof -ti :4000 | xargs kill -9
```

**`GM source: mock` in the UI** — API key not loaded. Check `.env`, run `mix dev.check`, restart `mix phx.server`.

**No LLM logs during play** — restart the server after editing `.env`. Create a new session (cached state may skip the LLM).

**Turns feel slow (> 3s)** — confirm `.env` uses `XAI_MODEL=grok-4.20-0309-non-reasoning` (not a reasoning model). Run `mix e2e.smoke` to check the 3s budget. Tier 1 skips LLM for clear actions via heuristics.

**PostgreSQL not running** (this machine uses mise Postgres, not Homebrew):

```bash
mise install postgres@18.6   # once
pg_ctl -D "$PGDATA" -l ~/.local/share/ex-tales-forge/postgres.log start
mix setup
```

`$PGDATA` is set from `.mise.toml`. Role `postgres` / trust on localhost. Stop with `pg_ctl -D "$PGDATA" stop`.

**See this project's compiler warnings** (not Hex dep noise):

```bash
mix warnings                 # compile --force --all-warnings --warnings-as-errors
MIX_ENV=test mix warnings
mix test --warnings-as-errors
```

`--warnings-as-errors` applies to this app only. Dependency compile warnings are not ours to fix.

## LLM providers

Set API keys in `.env` (loaded automatically in dev via `config/runtime.exs`). Provider resolution in `TalesForge.Config`:

1. If `LLM_PROVIDER` is set, use that provider explicitly (`mock`, `xai`, `openai`, `anthropic`).
2. Otherwise auto-select: `xai` if `XAI_API_KEY` is set, else `openai`, else `anthropic`, else `mock`.

| Provider | Key | Notes |
|----------|-----|-------|
| `mock` | none | Deterministic fallback for offline dev |
| `xai` | `XAI_API_KEY` | Default when key is present; model via `XAI_MODEL` (default `grok-4.20-0309-non-reasoning`) |
| `openai` | `OPENAI_API_KEY` | |
| `anthropic` | `ANTHROPIC_API_KEY` | |

### Two-tier LLM

Each turn runs Tier 1 intent extraction (small model, temp 0) then Tier 2 storytelling (Grok). Raw player text never reaches Tier 2 — only validated `PlayerAction` JSON.

| Setting | Default | Purpose |
|---------|---------|---------|
| `XAI_MODEL` | `grok-4.20-0309-non-reasoning` | Fast non-reasoning Grok for all tiers |
| `TIER1_MAX_TOKENS` | `400` | Intent JSON cap |
| `TIER2_MAX_TOKENS` | `700` | GM narration cap |
| `TIER1_HEURISTIC_THRESHOLD` | `0.85` | Skip Tier 1 LLM when heuristics are confident |
| `TIER1_TEMPERATURE` | `0` | Intent extraction |
| `TIER2_TEMPERATURE` | `0.7` | Storytelling |
| `TIER1_CONFIDENCE_THRESHOLD` | `0.75` | Clarification cutoff |

When `XAI_API_KEY` is set, both tiers use xAI Grok (never Ollama). Reasoning models are rejected. Clear actions use heuristics first (~0ms Tier 1). Target: full turn < 3s (`mix e2e.smoke` enforces).

Set `LOG_LEVEL=debug` in `.env` for full LLM request/response logging.

## Relationship to text-forge

| text-forge | ex-tales-forge |
|------------|----------------|
| `backend/app/rules/*.md` | `priv/rules/*.md` |
| `backend/app/prompts/*.txt` | `priv/prompts/*.txt` |
| File-based campaigns + git per turn | PostgreSQL runtime + Ecto schemas |
| FastAPI + Next.js | Phoenix LiveView + Jido |

When rules or prompts change in text-forge, sync the corresponding files here. Product principles are shared; storage and runtime differ by design.

## Game clock

- `world_tick` in `world_state` — 1 tick ≈ 15 in-game minutes; 4 ticks ≈ 1 hour; 96 ticks ≈ 1 day (~100 is a fair approximation)
- Ordinary turns advance `world_tick` by 1 via `TalesForge.Game.WorldClock`
- `wait` (rest, drink, gamble, sleep, "spend three days…") advances by parsed duration, capped at 7 days. Time does **not** pass while the player is AFK or logged off.
- `world_clock` in the UI is a **derived label** (e.g. `Day 1 · late afternoon`)

## NPC runtime

- Authored defs: `priv/npcs/*.json` (from text-forge) — `marta_kellen` (Weary Pilgrim), `worried_merchant` (Crossroads Square)
- Per-session persistence: `NpcInstance` (personality + `runtime_state` with memories, mood, `location_id`)
- GM `npc_memory_updates` are applied in `TurnProcessor` (the GM no longer returns `state_updates` or `overlay_deltas`; the server owns state)
- `present_npcs` syncs from NPC `location_id` vs player location
- `NPCRegistry` spawns/stops `TalesForge.Agents.NPCAgent` per present NPC; `NPCRecovery` re-syncs on boot

### NPC signal catalog (v1)

| Signal | Emitter | Handler | Effect |
|--------|---------|---------|--------|
| `world.time.passed` | `NPCSignals` / turn | `ReactToTime` | Escalate concern; evaluate initiative |
| `player.talked_to` | `NPCSignals` / speak turn | `OnPlayerTalked` | Memory + relationship bump |
| `conversation.message` | `NPCSignals` / overhear | `OnOverheard` | Memory for non-target NPCs |
| `{:npc_initiative, payload}` | `NPCInitiative` → PubSub | `PlayLive` | Proactive NPC line in narrative log |

Agent IDs: `npc-{session_id}-{npc_id}`. Initiative fires once per concern escalation when priority ≥8 and worry ticks ≥4 (~1 in-game hour).

## Scene + turn pipeline

Play always opens with a **scene** (GM exposition, not a turn). Player input is blocked until `last_scene_location` matches `location_id`.

1. `GameSessions.create_session/1` or `ensure_scene/1` — `TalesForge.Workers.ProcessScene` (Oban `:llm`) describes the location
2. PubSub `{:scene_completed, payload}` → LiveView narrative log + sidebar image (`image_url` when authored)
3. `GameSessions.submit_message/3` — Tier 1 intent (heuristic or LLM); returns `{:error, :needs_scene}` if scene pending
4. `TalesForge.Workers.ProcessTurn` — Tier 2 GM + mechanics
5. PubSub `{:turn_completed, payload}` → LiveView; if travel changed location, `needs_scene: true` triggers step 1 again

## Layout

```
lib/ex_tales_forge/
  agents/       # PlayerSessionAgent, NPCAgent
  actions/npc/  # Jido NPC signal handlers
  game/         # intent, mechanics, scene_processor, turn_processor
  workers/      # Oban ProcessScene, ProcessTurn
  schemas/      # Ecto runtime schemas
priv/rules/     # Markdown rulebook (from text-forge)
priv/prompts/   # LLM system prompts (from text-forge)
```

## Playtest agent (`/play_test`)

After code changes, run a live playthrough to verify intent extraction and GM responses:

```bash
mix phx.server   # terminal 1
mix e2e.smoke    # terminal 2
```

See [`.grok/skills/play-test/SKILL.md`](https://github.com/whyse-ab/ex-tales-forge/blob/main/.grok/skills/play-test/SKILL.md). Reports land in `priv/playtest/reports/`.