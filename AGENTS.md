# ex-tales-forge — Agent Rules

Rules for anyone, human or bot, who changes this repo. They summarise decisions
recorded in tales-forge-docs (`docs/decisions.md`, newest first) and the docs
named in each section. Last checked against `main` and tales-forge-docs on
2026-10-08.

## Project

Text-first AI RPG on the BEAM. Jido agents own the play-session runtime;
LiveView is the UI; PostgreSQL holds sessions and turn history; an AI game
master narrates.

Who we build for is in [PRODUCT.md](PRODUCT.md). Core table: **Hawk** (hard mode), **Paul** (role-playing, mechanics invisible), **Lotta** (identification, world and character), **Lars** (adventure). **Ronny** (win, loot, highest level) is the anti-persona — do not add systems that exist to let him win.

Rules identity (same file, Rules philosophy): prices ≈ human labor; you learn by failing, slowly, with transfer across related skills. Do not invent XP bars or loot-table gold. Fewer non-intuitive rules → easier to stay in the story.

## Stack

- **UI:** Phoenix LiveView + Tailwind
- **Runtime:** Jido 2.x agents + actions
- **Persistence:** plain Ecto + PostgreSQL (`GameSession`, `Turn`, `NpcInstance`, `Character`, `AICall`, …)
- **Jobs:** Oban (queues `default` and `llm`; `ProcessScene`, `ProcessTurn`)
- **AI:** xAI Grok for prose (`TalesForge.LLM`); TypeSafe Jev (Hex `jev`) for typed answers from free text
- **Authored content:** pack files under `priv/` (`priv/adventures/*`, `priv/npcs/*.json`, `priv/rules`, `priv/prompts`, `priv/characters`), loaded by `Game.Pack` / `NPC` and copied into each session at creation. Edited in git; the admin NPC definition pages are read-only.
- **Admin:** `TalesForge.Admin` + LiveViews on plain Ecto changesets (`to_form/2`); JSON editors for complex maps like `world_state`.

## How changes land

Sources: tales-forge-docs `docs/decisions.md` ("Docs go straight to main",
"Decisions are recorded in this file", "Branching and environments"),
`docs/environments.md`.

### Code (this repo)

1. **Every code change goes through a branch and a pull request.** Never commit to `main` directly.
2. **Merging or deploying needs Fredrik's explicit OK.** A merge to `main` deploys: CI's "Deploy to production" job runs after Test and Dialyzer pass, and playtest follows automatically. Bots never merge, never run `fly deploy`, and never change Fly apps, databases, tokens, secrets or anything that adds cost without that OK (`docs/environments.md`, "What needs Fredrik's OK").
3. **CI must be green.** The Test and Dialyzer jobs are required checks on `main`.
4. Before you finish, rebase on `origin/main`; other agents merge in parallel.

### Docs (tales-forge-docs)

1. Documentation is committed **straight to `main`**, without pull requests. Pull with `git pull --rebase` before pushing. If something is wrong, revert it.
2. **Every decision goes into `docs/decisions.md`**, newest at the top. Each entry has a date, the decision, why, and a link to the details.
3. Changing a decision means adding a new entry that supersedes the old one; old entries are not rewritten.
4. Design notes, plans and history belong in tales-forge-docs, not in this repo's code or code docs. Module docs describe what the code does now.

### Git workflow

```bash
git fetch origin
git checkout -b feature/<short-name> origin/main
# ... work, commit ...
git fetch origin && git rebase origin/main
git push -u origin feature/<short-name>   # then open a PR
```

Use kebab-case names that describe the work (`feature/two-tier-llm`, `fix/oban-migration`). If you are on `main` with uncommitted work, move it to a new branch before continuing.

## Non-negotiables

1. **Plain Ecto + Repo everywhere** (play loop, Jido, Oban, GameSessions, NPC logic, admin). Ash was removed on 2026-10-07 ([#47](https://github.com/whyse-ab/ex-tales-forge/pull/47)); revisit only if an in-app adventure editor needs it. Authored content lives in pack files, not database tables. Don't add a second data layer without a decision entry.
2. **Call-type rule** (decision 2026-10-07, tales-forge-docs `docs/call-types.md`): known structured input + structured output = Elixir function; unstructured input + structured output = Jev; prose output = LLM. Asking the LLM for structured output is a smell. Elixir is exact, free and instant, Jev is fast and cheap, the LLM is the slowest and most expensive: use the LLM last, with the smallest input possible.
3. **One Character type** for player characters and NPCs: OCEAN, personality-filtered memory, a Maslow level and concerns; only the controller differs (`player`, `gm` or `bot`). `TalesForge.Characters` keeps a `characters` row per PC and NPC in step after every turn; the game still reads `world_state["character"]` and `npc_instances` until the Character plan's read switch (tales-forge-docs `docs/plan-unify-character.md`). Don't add a separate PC or NPC model.
4. **Intent before the GM.** Tier 1 intent (heuristic, or the intent LLM when the heuristic is unsure) runs first. The GM gets the validated `PlayerAction` (on the heuristic path its `overall_intent` is the player's text, sanitised and capped at 500 characters), never the raw message.
5. **The server owns mechanics.** It rolls dice and applies LP, inventory, coins, prices and time; the LLM narrates and never invents mechanics.
6. Important authored state stays human-readable: `priv/rules/*.md`, `priv/prompts/*.txt`, pack files.
7. LLM replies use structured JSON with a strict schema (Tier 1 `PlayerAction` via `TalesForge.Game.Intent`; the scene and GM reply via `TalesForge.LLM`).
8. Turn history is auditable: every turn is persisted in the `Turn` schema.
9. **Secret names only, never values**, in code, docs, commits, PRs, logs and chat. Secrets live in Fly secrets or GitHub Actions secrets (tales-forge-docs `docs/fly-secrets.md`).

## Sign-in and access

Source: decision 2026-10-07 "GitHub team sign-in is the only login on production and playtest" ([#54](https://github.com/whyse-ab/ex-tales-forge/pull/54)), `TalesForge.AdminAuth`.

- "Sign in with GitHub", checked against the team in `ADMIN_GITHUB_TEAM` (`whyse-ab/tales-forge`), is the only login. Only active members get in (pending invites don't count); membership is rechecked on every request and LiveView mount (cached for 5 minutes). Logins last up to 30 days.
- **Every page and LiveView needs a signed-in team member**: play, character creation, admin, costs, code docs and playtest reports. Any team member gets the admin pages; there is no second admin check.
- Open signed out: `/health` (the Fly check), the login page, the GitHub OAuth request and callback, logout, the static files the login page needs, and the token-guarded machine-to-machine `GET /internal/costs` (`COSTS_PEER_TOKEN`; 404 while unset).
- **No unauthenticated route, LiveView event or endpoint may start an AI call.**
- `test/ex_tales_forge_web/access_control_test.exs` holds the public route list and fails for any other route reachable signed out. A new public route needs a reason there and a decision.
- Email magic links are gone (routes, form and sending code). `ADMIN_EMAILS` lets nobody in, and nothing sends mail.

## Feature flags

Environment variables read through `TalesForge.Config`. Flags marked "new sessions" are fixed per session at creation (`world_state["variant"]`, `world_state["features"]`), so changing them affects new sessions only. Current per-app values are in tales-forge-docs `docs/fly-secrets.md`; `fly.playtest.toml` `[env]` sets some for playtest.

| Flag | What it does | Default | Production | Playtest |
|------|--------------|---------|------------|----------|
| `GAME_VARIANT` | Behaviour variant of new sessions: `default` or `baseline` (`TalesForge.Game.Variant`). The playtest runner can pick a variant per run | `default` | not set in `fly.toml` | not set in `fly.playtest.toml`; runs choose per run |
| `INN_WORLD` | Places and people around the Valley Inn for new Tin Valley sessions (`TalesForge.Game.Features`) | off | off | `on` (`fly.playtest.toml`) |
| `WORLD_ANTAGONIST` | The Tinjacks antagonist for new Tin Valley sessions; needs `INN_WORLD` | off | off | off until [#73](https://github.com/whyse-ab/ex-tales-forge/pull/73) sets it |
| `NPC_REACTIONS` | Jev NPC reaction before each GM call (`TalesForge.Game.NpcReactions`; needs `TYPESAFE_API_KEY`) | off | off | `on` (Fly secret) |
| `WORLD_AGENTS` | World-agents prototype: persons and locations hold facts for the GM; also turns on NPC reactions | off | off | off |
| GM reply mode | Only the structured GM reply schema exists on `main`. The prose-only prototype `GM_REPLY_MODE=prose` is in the unmerged [#38](https://github.com/whyse-ab/ex-tales-forge/pull/38) | structured | structured | structured |
| `PLAYTEST_RUNNER_ENABLED` | Persona bot runner; only `true` enables it | off | **never set** | `true` |

The baseline variant gets no world features.

## Money and AI spend

Sources: decision 2026-10-07 "All amounts in USD", `TalesForge.AICalls`, tales-forge-docs `docs/fly-secrets.md`.

- **All amounts are in USD.** AI costs are stored as integer **micro-USD** (`ai_calls`, `playtest_runs`); never floats. The provider-billed cost wins when present, otherwise it comes from `:llm_prices` in config. The costs page shows SEK beside USD at a fixed dated rate; fixed costs may be configured as SEK per year in `config :ex_tales_forge, TalesForge.Costs`.
- **Every unit of work in a turn gets an `ai_calls` row** with a `call_type` (`llm`, `jev`, `function`) and adventure and game-system tags. Persona and scorer (bot) costs are kept apart from game cost.
- **AI spend caps**, decimal USD, read in `config/runtime.exs` and checked before each request:

| Variable | Caps | When unset |
|----------|------|------------|
| `AI_CAP_SESSION_USD` | Game calls per session (not persona or scorer) | off |
| `AI_CAP_DAY_USD` | All calls since midnight Europe/Stockholm | off |
| `AI_CAP_PERSONA_RUN_USD` | The persona bot's own calls per playtest run; hitting it stops the run | $0.50 |

Production has no caps set; playtest has session and day caps. Changing a cap, or adding an AI key, needs Fredrik's OK.

## Prompts and caching

Sources: `test/ex_tales_forge/game/prompt_prefix_test.exs`, `test/ex_tales_forge/game/prompt_golden_test.exs`, decisions 2026-10-07 "No length limits in the GM reply schema" and "Each bot call gets its own conversation id".

- **Static parts first.** xAI caches the longest identical prefix, so the shared narrator text and the rules come first and are byte-identical for the scene call and every GM turn of an adventure; session-stable content follows and does not change between turns; anything per turn (state, turn number, the action, NPC reactions, world facts, prices) comes last. The prefix test enforces this.
- **Golden prompts stay byte-identical** unless a change is intended. The fixtures in `test/fixtures/prompts/` (one per adventure and variant) only change on purpose: regenerate with `UPDATE_PROMPT_GOLDEN=1 mix test test/ex_tales_forge/game/prompt_golden_test.exs`, review the diff and say so in the PR.
- **The baseline variant is frozen.** `priv/prompts/variants/baseline/`, the packs' `variants/baseline/` folders and the `*.baseline.txt` fixtures are the pre-rework game and must not change while the baseline arm exists; new behaviour goes into the default variant only.
- The strict GM and scene reply schema has no `maxLength` or `maxItems` (they disable xAI's prompt cache); caps are applied in code when the reply is parsed.
- Only the scene and GM calls share the session's `x-grok-conv-id`; persona, scorer, intent and fact-extraction calls use `<session>:<purpose>`.
- Prompt files are content: a code change must not alter their text by accident.

## Environments and deploys

Sources: tales-forge-docs `docs/environments.md`, `docs/infrastructure.md`, decision 2026-10-06 "tales-forge.ai stays on Netlify for now".

- Production: Fly app `tales-forge` ([tales-forge.fly.dev](https://tales-forge.fly.dev)). Playtest: `tales-forge-playtest` ([tales-forge-playtest.fly.dev](https://tales-forge-playtest.fly.dev)), deployed right after production. Region `arn`. Each app has its own secrets and its own xAI key.
- **`tales-forge.ai` stays on Netlify** until the Fly app replaces it. No environment gets Fly certificates or DNS changes; **deploys are verified on the `fly.dev` apps**.
- The code docs (this site) are built in the Docker builder stage and served at `/admin/code-docs` on both apps, behind the sign-in.
- Manual `fly deploy` (`docs/DEPLOY-FLY.md`) is only a fallback when Actions is down, and needs Fredrik's OK like any deploy.

## Removed — do not bring back without a decision

- **Ash** (`ash`, `ash_postgres`, `ash_phoenix`, igniter) and the authoring tables, 2026-10-07 ([#47](https://github.com/whyse-ab/ex-tales-forge/pull/47)).
- **Email magic-link sign-in** and the `ADMIN_EMAILS` allowlist, 2026-10-07 ([#54](https://github.com/whyse-ab/ex-tales-forge/pull/54)).
- **`jido_ai`**: the unused dependency was dropped (module audit, tales-forge-docs `docs/module-audit-2026-10-07.md`). LLM calls go through `TalesForge.LLM` only.
- GM bookkeeping fields: the GM no longer returns `state_updates`, `overlay_deltas` or `new_facts`; the server owns state, and with `WORLD_AGENTS` on, facts are read from the narration after the turn (`TalesForge.World.Extract`).

## Elixir coding guidelines

### Docs, types and tests (mandatory)

Humans may need to understand the code one day, including code written by bots. The full standard is tales-forge-docs `docs/coding-standards.md` (decision 2026-10-07 "Coding standards: documented, typed, tested, enforced in CI").

- `@moduledoc` on every module (`@moduledoc false` only for real internals): what it is for and how it fits in. Credo checks it.
- `@doc` on every public function (`@doc false` if public only for tests): what it returns and when it fails. Add a doctest where an example helps and the function is pure. `test/ex_tales_forge/coding_standards_test.exs` checks the backfilled modules.
- `@spec` on every public function, checked by **Dialyzer** (`mix dialyzer`). Structs get a `@type t`. Credo `Readability.Specs` enforces presence for the backfilled files listed in `.credo.exs`. An accepted Dialyzer warning goes in `.dialyzer_ignore.exs` with a reason (empty today).
- **Credo strict** (`mix credo --strict`) and `mix format`, no new issues.
- **ExDoc**: `mix docs` must build without warnings (CI runs `mix docs --warnings-as-errors`).
- **Tests for every change**; a bug fix gets a test that fails without it. `mix test --cover` fails below the threshold in `mix.exs`; raise it as coverage grows, never lower it to pass.
- **CI enforces all of this** in two required jobs: **Test** (compile with warnings as errors, format, Credo, tests with coverage, docs, `mix hex.audit`) and **Dialyzer**.
- Module docs describe current behaviour, not where the code came from or how it used to work; history goes to tales-forge-docs.
- Older modules are backfilled when you touch them; then add them to the lists above.

### Formatting

- Run `mix format` before every commit; [.formatter.exs](.formatter.exs) is authoritative (Phoenix, Ecto, LiveView HEEx).
- `mix precommit` runs everything CI runs.

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
mix credo --strict  # lint
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
mix precommit                 # everything CI runs (run before opening a PR)
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

Jev calls (NPC reactions, persona-affect scoring) use `TYPESAFE_API_KEY`.

### Two-tier LLM

Each turn runs Tier 1 intent extraction (heuristic first, else a small-model LLM call at temperature 0) then Tier 2 storytelling (Grok). The GM sees the validated `PlayerAction`, not the raw message.

| Setting | Default | Purpose |
|---------|---------|---------|
| `XAI_MODEL` | `grok-4.20-0309-non-reasoning` | Fast non-reasoning Grok for all tiers |
| `TIER1_MODEL`, `TIER2_MODEL` | unset (`XAI_MODEL`) | Per-tier model override |
| `TIER1_MAX_TOKENS` | `400` | Intent JSON cap |
| `TIER2_MAX_TOKENS` | `700` | GM narration cap |
| `TIER1_HEURISTIC_THRESHOLD` | `0.85` | Skip Tier 1 LLM when heuristics are confident |
| `TIER1_TEMPERATURE` | `0` | Intent extraction |
| `TIER2_TEMPERATURE` | `0.7` | Storytelling |
| `TIER1_CONFIDENCE_THRESHOLD` | `0.75` | Clarification cutoff |

When `XAI_API_KEY` is set, both tiers use xAI Grok (never Ollama). A reasoning model in `XAI_MODEL` is replaced by the default model for game turns (too slow). Clear actions use heuristics first (~0ms Tier 1). Target: full turn < 3s (`mix e2e.smoke` enforces).

## Game clock

- `world_tick` in `world_state` — 1 tick ≈ 15 in-game minutes; 4 ticks ≈ 1 hour; 96 ticks ≈ 1 day (~100 is a fair approximation)
- Ordinary turns advance `world_tick` by 1 via `TalesForge.Game.WorldClock`
- `wait` (rest, drink, gamble, sleep, "spend three days…") advances by parsed duration, capped at 7 days. Time does **not** pass while the player is AFK or logged off.
- `world_clock` in the UI is a **derived label** (e.g. `Day 1 · late afternoon`)

## NPC runtime

- Authored defs: `priv/npcs/*.json` — `marta_kellen` (Weary Pilgrim), `worried_merchant` (Crossroads Square) for Crossroads; Tin Valley's NPCs live in its pack (`priv/adventures/tin_valley/`)
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
priv/rules/     # Markdown rulebook (global; packs may carry their own rules/)
priv/prompts/   # LLM system prompts (variants/<variant>/ replaces whole files)
priv/adventures/ # adventure packs: places, NPCs, rules, extensions, variants
```

## Playtest agent (`/play_test`)

After code changes, run a live playthrough to verify intent extraction and GM responses:

```bash
mix phx.server   # terminal 1
mix e2e.smoke    # terminal 2
```

See [`.grok/skills/play-test/SKILL.md`](.grok/skills/play-test/SKILL.md). Reports land in `priv/playtest/reports/`.