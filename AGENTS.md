# ex-tales-forge — Agent Rules

Read docs/principles.md first; the north star is ETC, Easy To Change.

Rules for anyone, human or bot, who changes this repo. They summarise decisions
recorded in `docs/` (`docs/decisions.md`, newest first) and the docs
named in each section. Last checked against `main` and `docs/` on
2026-10-08.

## Project

Text-first AI RPG on the BEAM. One `World.Instance` process per active
session runs its turns; LiveView is the UI; PostgreSQL holds sessions and turn history; an AI game
master narrates.

ex-tales-forge stands on its own. Nothing is synced from an earlier app: the
rules, prompts, packs and code here are maintained in this repo, and any
history lives in `docs/`.

Who we build for is in [PRODUCT.md](PRODUCT.md). Core table: **Hawk** (hard mode), **Paul** (role-playing, mechanics invisible), **Lotta** (identification, world and character), **Lars** (adventure). **Ronny** (win, loot, highest level) is the anti-persona — do not add systems that exist to let him win.

Rules identity (same file, Rules philosophy): prices ≈ human labor; you learn by failing, slowly, with transfer across related skills. Do not invent XP bars or loot-table gold. Fewer non-intuitive rules → easier to stay in the story.

Skill growth (decision 2026-10-09): a failed or partial roll banks one improvement chance for that exact skill (a success banks nothing, nothing spills to other skills, the linked stat adds nothing), and banked chances are resolved on a long rest or sleep (`TalesForge.Game.Progression`): one roll costs ceil(level / 3) banked LP, at most +1 per skill per night, the skill's LP are gone afterwards, and from level 10 the character must also reflect on the skill (`TalesForge.Game.Reflection`) or its LP stay banked. Physical skills (combat, dodge, climbing, lockpicking; `Progression.immediate_skills/0`) are resolved at the end of the turn of the failure instead (`Progression.resolve_turn/3`), same cost, roll and reflection gate, at most +1 per skill per long-rest cycle (`"improved_since_rest"`). The numbers are in `config/config.exs`. Plain talk doesn't roll (decisions 2026-10-07 and 2026-10-09): persuasion, deception and intimidation only when the character tries to change someone's mind against their interest.

## Stack

- **UI:** Phoenix LiveView + Tailwind
- **Runtime:** plain OTP: one `TalesForge.World.Instance` GenServer per active session (`World.Registry`, `World.Supervisor`, `World.TaskSupervisor`); no Jido (removed in refactor step 10f)
- **Persistence:** plain Ecto + PostgreSQL (`GameSession`, `Turn`, `NpcInstance`, `Character`, `AICall`, …)
- **Jobs:** Oban (queues `default` and `llm`; `ProcessScene`, `ProcessTurn`).
- **Workflow (team tools):** a separate app, `whyse-ab/workflow` (https://whyse-workflow.fly.dev). This app sends work-log turns to it (`TalesForge.WorkflowClient.Http`, `WORKFLOW_API_TOKEN`) and serves `GET /internal/product/*` to it (`PRODUCT_APP_API_TOKEN`). The old Workflow paths redirect there for 30 days (`TalesForge.AppRole.workflow_paths/0`).
- **AI:** xAI Grok for prose (`TalesForge.LLM`); TypeSafe Jev (Hex `jev`) for typed answers from free text
- **Authored content:** pack files under `priv/` (`priv/adventures/*`, `priv/npcs/*.json`, `priv/rules`, `priv/prompts`, `priv/characters`), loaded by `Game.Pack` / `NPC` and copied into each session at creation. Edited in git; the admin NPC definition pages are read-only.
- **Admin:** `TalesForge.Admin` + LiveViews on plain Ecto changesets (`to_form/2`); JSON editors for complex maps like `world_state`.

## How changes land

Sources: `docs/decisions.md` ("Docs go straight to main",
"Decisions are recorded in this file", "Branching and environments"),
`docs/environments.md`.

### Code (this repo)

1. **Every code change goes through a branch and a pull request.** Never commit to `main` directly.
2. **Merging or deploying needs Fredrik's explicit OK.** A merge to `main` does not deploy to playtest automatically (hobby mode; `.github/workflows/playtest.yml` is started only by hand). Production for the normal lane is a separate, manual step: after Fredrik has OK'd the build, the "Deploy to production" workflow is started for that commit (`gh workflow run deploy-production.yml -f sha=<full sha>`; `.github/workflows/deploy-production.yml`, GitHub environment `production`). A bot starts it only on Fredrik's explicit OK for that sha. Bots never merge, never run `fly deploy`, and never change Fly apps, databases, tokens, secrets or anything that adds cost without that OK (`docs/environments.md`, "What needs Fredrik's OK"). Exceptions: the admin and security lanes go straight to production through `.github/workflows/deploy-lanes.yml` after green CI (security through `production-security` at all hours). Outside working hours the bots may also merge and deploy a security-fix PR, in that lane only, through `security-lane.yml` and `security-fix-deploy.yml` (`docs/environments.md`, "Off-hours security fixes").
3. **CI must be green.** The Test and Dialyzer jobs are required checks on `main`.
4. Before you finish, rebase on `origin/main`; other agents merge in parallel.

### Docs (this repo, `docs/`)

1. Documentation is committed **straight to `main`**, without pull requests. Pull with `git pull --rebase` before pushing. If something is wrong, revert it.
2. **Every decision goes into `docs/decisions.md`**, newest at the top. Each entry has a date, the decision, why, and a link to the details.
3. Changing a decision means adding a new entry that supersedes the old one; old entries are not rewritten.
4. Design notes, plans and history belong in `docs/`, not in this repo's code or code docs. Module docs describe what the code does now.

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

1. **Plain Ecto + Repo everywhere** (play loop, Oban, GameSessions, NPC logic, admin). Ash was removed on 2026-10-07 ([#47](https://github.com/whyse-ab/ex-tales-forge/pull/47)); revisit only if an in-app adventure editor needs it. Authored content lives in pack files, not database tables. Don't add a second data layer without a decision entry.
2. **Call-type rule** (decision 2026-10-07, `docs/call-types.md`): known structured input + structured output = Elixir function; unstructured input + structured output = Jev; prose output = LLM. Asking the LLM for structured output is a smell. Elixir is exact, free and instant, Jev is fast and cheap, the LLM is the slowest and most expensive: use the LLM last, with the smallest input possible.
3. **One Character type** for player characters and NPCs: OCEAN, personality-filtered memory, a Maslow level and concerns; only the controller differs (`player`, `gm` or `bot`). `TalesForge.Characters` keeps a `characters` row per PC and NPC in step after every turn; the game still reads `world_state["character"]` and `npc_instances` until the Character plan's read switch (`docs/plan-unify-character.md`). Don't add a separate PC or NPC model.
4. **Intent before the GM; the GM gets a typed struct plus a short quote.** The intent step runs first: one Jev call (`INTENT_JEV=on`, `TalesForge.IntentJev`), with the Elixir heuristic as the fallback. There is no intent LLM call (decision 2026-10-12). The GM gets the validated, typed `PlayerAction` plus a short, sanitised quote of the player's words (`overall_intent`, at most 500 characters), so it keeps the player's tone. This is intended (decisions 2026-10-07 "GM pipeline direction" and 2026-10-08). When Jev gives no quote, `overall_intent` is a typed summary of the message, sanitised the same way. The full raw message never goes to the GM.
5. **The server owns mechanics.** It rolls dice and applies LP, inventory, coins, prices and time; the LLM narrates and never invents mechanics. A player's claim about the character's own state (an item, coins, a purchase or a kill the session doesn't back) is checked in Elixir against the session (`TalesForge.Game.PremiseCheck`), not by Jev; a false one reaches the GM as a short correction in the per-turn prompt (decision 2026-10-09).
6. Important authored state stays human-readable: `priv/rules/*.md`, `priv/prompts/*.txt`, pack files.
7. LLM replies use structured JSON with a strict schema (Tier 1 `PlayerAction` via `TalesForge.Game.Intent`; the scene and GM reply via `TalesForge.LLM`).
8. Turn history is auditable: every turn is persisted in the `Turn` schema.
9. **Secret names only, never values**, in code, docs, commits, PRs, logs and chat. Secrets live in Fly secrets or GitHub Actions secrets (`docs/fly-secrets.md`).

## Language: positive framing and ASD-STE100

Decision: `docs/decisions.md`, 2026-10-10, "Positive framing and ASD-STE100 language standard" (Fredrik).

**1. Say confidence, not doubt.** In the UI, playtest reports, scores, prompts that show in reports, and docs, write "confidence" or "certainty". Do not write "unsure", "uncertain", "uncertainty" or "unsureness". Give the positive quantity directly. Do not use minimized negatives ("not unlikely", "fewer failures") or double negatives.

| Write | Not |
|---|---|
| `4.21/5 · confident 70%` | `4.21/5 · unsure 30%` |
| `3 low-confidence turns` | `3 unsure turns` |
| `Jev had low confidence here.` | `Jev was very unsure here.` |
| `9 of 10 checks pass.` | `Only 1 check fails.` |
| `The result is likely.` | `The result is not unlikely.` |

**2. Code, comments, moduledocs and docs use ASD-STE100 Simplified Technical English.**

- Short sentences: 20 words or fewer for an instruction, 25 for a description.
- One instruction in one sentence. Start an instruction with the verb.
- Active voice. Name the actor.
- Use approved words with one meaning. Use the same word for the same thing every time.

| Write | Not |
|---|---|
| `Start the poller. Then read the snapshot.` | `The snapshot should be read once the poller has been started.` |
| `The scorer writes one row for each turn.` | `A row is written per turn by the scorer.` |
| `@doc "Returns the confident share (0 to 1)."` | `@doc "Basically gives you roughly how sure-ish Jev was."` |

Old names (for example `unsure_share`, `unsure_pct`) change to the confidence form when you touch them. A separate rename PR does the rest. Do not change the GM, Jev or intent prompts for wording only: a prompt change needs its own decision, and the GM prompt golden test stays byte-identical.

The same rule is in `CONTRIBUTING.md`.

## Sign-in and access

Source: decision 2026-10-07 "GitHub team sign-in is the only login on production and playtest" ([#54](https://github.com/whyse-ab/ex-tales-forge/pull/54)), `TalesForge.AdminAuth`.

- "Sign in with GitHub", checked against the team in `ADMIN_GITHUB_TEAM` (`whyse-ab/tales-forge`), is the only login. Only active members get in (pending invites don't count); membership is rechecked on every request and LiveView mount (cached for 5 minutes). Logins last up to 30 days.
- **Every page and LiveView needs a signed-in team member**: play, character creation, admin, costs, code docs and playtest reports. Any team member gets the admin pages; there is no second admin check.
- Open signed out: `/health` (the Fly check), the login page, the GitHub OAuth request and callback, logout, the static files the login page needs, and the token-guarded machine-to-machine `GET /internal/costs` and `GET /internal/version` (both `COSTS_PEER_TOKEN`; 404 while unset). `/internal/version` returns only the app's role and running commit. The product-app API `GET /internal/product/costs|online|running-commits` (`PRODUCT_APP_API_TOKEN`; 404 while unset) and the Workflow app's `POST /internal/workflow/work-log/turns` (`WORKFLOW_API_TOKEN`, sent by `TalesForge.WorkflowClient.Http`) are the only data paths between Workflow and the product app. The old Workflow paths (`TalesForge.AppRole.workflow_paths/0`) answer a 307 redirect to Workflow for 30 days, signed in or not.
- **No unauthenticated route, LiveView event or endpoint may start an AI call.**
- `test/ex_tales_forge_web/access_control_test.exs` holds the public route list and fails for any other route reachable signed out. A new public route needs a reason there and a decision.
- Email magic links are gone (routes, form and sending code). `ADMIN_EMAILS` lets nobody in, and nothing sends mail.

## Feature flags

Environment variables read through `TalesForge.Config`. Flags marked "new sessions" are fixed per session at creation (`world_state["features"]`), so changing them affects new sessions only (`INTENT_JEV` is pinned as `world_state["intent_jev"]`). Current per-app values are in `docs/fly-secrets.md`; `fly.playtest.toml` `[env]` sets some for playtest.

| Flag | What it does | Default | Production | Playtest |
|------|--------------|---------|------------|----------|
| `INN_WORLD` | Places and people around the Valley Inn for new Tin Valley sessions (`TalesForge.Game.Features`) | off | off | `on` (`fly.playtest.toml`) |
| `WORLD_ANTAGONIST` | The Tinjacks antagonist for new Tin Valley sessions; needs `INN_WORLD` | off | off | `on` (`fly.playtest.toml`, [#73](https://github.com/whyse-ab/ex-tales-forge/pull/73)) |
| `NPC_REACTIONS` | Jev NPC reaction before each GM call (`TalesForge.Game.NpcReactions`; needs `TYPESAFE_API_KEY`) | off | off | `on` (Fly secret) |
| `WORLD_AGENTS` | World-agents prototype: persons and locations hold facts for the GM; also turns on NPC reactions | off | off | off |
| `CODE_HEAT_MAP` | Daily call-time sample of the app's functions for the code heat map on `/admin/operate/code-heat` (`TalesForge.CodeHeat`). Only `on` (or `true`, `1`) turns it on. Production stays off, also with the variable set | off | off (refused) | `on` (`fly.playtest.toml`) |
| `PLAYTEST_RUNNER_ENABLED` | Persona bot runner; only `true` enables it, and never on production (`TalesForge.AppRole`) | off | **never set** (refused anyway) | `true` |
| `INTENT_JEV` | New sessions: player intent as one Jev call (`TalesForge.IntentJev`). `on` = Jev drives the turn, heuristic on error or timeout; `shadow` = the heuristic plays, the Jev read is only logged (`ai_calls` purpose `turn.intent_shadow`); `off` = the heuristic plays. Needs `TYPESAFE_INTENT_API_KEY` (secret). The playtest runner can pick per run (`intent_jev`). Raises at boot on any other value | `on` | `on` (Fly secret) | `on` (Fly secret) |
| `INTENT_ACT_MIN_CONFIDENCE` / `INTENT_ASK_BELOW_CONFIDENCE` | `INTENT_JEV=on` bands on the calibrated confidence: act at or above, ask below (only when the top two readings play out differently), best guess between | 0.70 / 0.45 | not set | not set |
| `INTENT_ASK_BELOW_RAW_CONFIDENCE` | `INTENT_JEV=on`: also ask (top two readings play out differently) when Jev's **raw** confidence is below this, even if calibration lifted it into the act band; `0` turns the raw check off | 0.45 | not set | not set |
| `INTENT_JEV_TIMEOUT_MS` | `INTENT_JEV=on`: hard deadline of the Jev call on the player's clock before the heuristic takes over | 1500 | not set | not set |
| `PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE` | `INTENT_JEV=on`: the GM gets the player's own words only for `benign` at or above this; otherwise a typed summary | 0.90 | not set | not set |
| `TURN_OUTCOME_RECORD` | Turn pipeline PR 1: the outcome record of the mechanics (played action accepted or rejected with the reason, coin and item deltas, clock, location; `TalesForge.Game.OutcomeRecord`) goes to the per-turn GM prompt and to the turn as a `turn.outcome` event. Off: the GM prompt is as before. Only `on` (or `true`, `1`) turns it on | off | off | off |
| `TURN_PREMISE_FIRST` | Turn pipeline PR 2: the premise check (`TalesForge.Game.PremiseCheck`) runs before the mechanics and the NPCs, against the state before the turn. A claim that the state contradicts blocks the action: no roll, no booking, no game time. The GM still gets the correction. Off: the check runs after the NPCs, as before. Only `on` (or `true`, `1`) turns it on | off | off | off |
| `TURN_STATE_FROM_MECHANICS` | Turn pipeline PR 3: coins, items, location and clock come only from stage 3. The prose post-check (`TalesForge.Game.ProseCheck`) logs each prose/record mismatch and stores it as a `turn.prose_mismatch` event (log only, no GM re-run). A room payment with nobody here who rents rooms is rejected (provisional rule, `TalesForge.Game.TurnRules`). Only `on` (or `true`, `1`) turns it on | off | off | off |
| `TURN_APPLY_OUTCOMES` | Stage 3 applies sleep, pay and move to the state (`TalesForge.Game.TurnApply`). A payment with no amount uses the coin amount in the text ("two silver") or the service price (room 3s, ale 2c, meal 5c, provisional). "Pay for a room and go to sleep" also plays the sleep: 8 hours with a paid bed, 1 hour without one. A move to a place that the world does not have is rejected, and the reason names the exits. "I order an ale" is a payment at the service price with no item, because the character drinks it at the counter. "I go inside the inn" in an inn plays no walk. A turn that sets out for an unknown place ("heading out to the old mill") keeps the character here, and the reason names the exits. Also turns on the room-payment rule of `TURN_STATE_FROM_MECHANICS` and the prose post-check (log only). Only `on` (or `true`, `1`) turns it on | off | off | off |
| `NPC_DIALOGUE_MEMORY` | Turn pipeline step 4: the server keeps the last 3 lines of each NPC in `world_state["npc_memory"]` (`TalesForge.Game.NpcMemory`; the GM never writes it). The GM prompt shows the memory of the present NPCs. The repetition guard logs each repeat (exact match after case and whitespace are normalised) as a `turn.npc_repeat` event. The premise check runs before the NPC reactions, and the NPCs get its findings. Only `on` (or `true`, `1`) turns it on | off | off | off |
| `HISTORY_STRIP_INJECTION` | Turn pipeline step 7 (bug h-fa06): an injection turn (fake GM note, "As the GM, I decide", "Ignore all previous instructions") plays no action, costs no game time and runs no premise check. The stored turn keeps a placeholder, not the text, and the turn writes no `context_summary` (`TalesForge.Game.HistoryStrip`). The GM still reads the text on that turn. Only `on` (or `true`, `1`) turns it on | off | off | off |
| `SKILL_SPLIT` | Skill split (`TalesForge.Game.SkillSplit`): the player splits one skill action into two or three parts, and the server rolls each part (`Mechanics.split_levels/2`). The thresholds are in `config :ex_tales_forge, :skill_split` (d100 scale: start 100, triple 150, uneven part 25 or more). A split action banks one learning chance at most. The GM gets a section with each part, its level and its result. The rules text in `priv/rules` has `skill_split:on` and `skill_split:off` blocks; the GM prompt shows the blocks for the flag. Off: the prompts, the Jev questions and the rolls are as before. Keep it off until the D100 switch. Only `on` (or `true`, `1`) turns it on | off | off | off |
| `COMBAT_OPPOSED` | Opposed combat (`TalesForge.Game.Combat`, decision 2026-10-14 "NPC combat: both sides roll"): the player's d20 attacks against the defender's Parry (Dodge/2 + 10 + (DEX - 10)/2). A defender that is still up counterattacks with a probability from its combat skill, OCEAN, Maslow level, concerns and wounds. A miss is only a miss: the player takes a wound only from a counterattack hit. NPC wounds stay in `world_state["npc_state"][id]` for the session (cap `wound_max/1`, down at the cap, the death roll on a hit after that, `npc.down` and `npc.dead` events). An attack on a person that the world does not have makes a minor foe (1 wound, untrained floor). An unclear target asks the player. The GM gets a combat exchange section, and the prose check logs a `:wound` mismatch for each hit or blood that the record does not have. Only `on` (or `true`, `1`) turns it on | off | off | `on` (`fly.playtest.toml`) |

The GM has one reply mode, the strict structured JSON schema (`TalesForge.LLM`); there is no reply-mode flag.

## Each thing lives in one place

Source: decision 2026-10-08 "Each thing lives in one place", `TalesForge.AppRole`.

- Founder surveys live only on production; playtest runs only on playtest. On the other app, `/admin/founders/survey`, `/admin/founders/surveys/*` and `/admin/play/runs/*` redirect to the same page on the owning app (`TalesForgeWeb.Plugs.HomeApp`), the admin nav links there (cross-app links use the old paths, `TalesForge.AdminPaths.legacy/1`, which every version of either app understands), and the data is refused (`Surveys.save_section/4` returns `{:error, :wrong_app}`; `Playtest.Runner.enabled?/0` is false on production).
- The role comes from `FLY_APP_NAME` (a name with "playtest" = playtest, no name = local, where both live); the apps' base URLs are `config :ex_tales_forge, TalesForge.AppRole` in `config/config.exs`. Don't hardcode hostnames elsewhere.

## The admin area

Source: decision 2026-10-10 "Admin area grouped by purpose", `TalesForgeWeb.AdminSections`, `TalesForge.AdminPaths`.

- The admin pages are grouped by purpose: Founders (`/admin/founders/*`, and links to `/team` and the decision queue on Workflow), Play and test (`/admin/play/*`), Operate (`/admin/operate/*`), Develop (`/admin/code-docs`), Docs (`/admin/docs`) and a collapsed Archive (`/admin/archive/*`). The nav and the admin home's cards both come from `TalesForgeWeb.AdminSections`; add a page there, not in the nav by hand.
- Old admin URLs keep working: `TalesForge.AdminPaths` maps each moved prefix and the router sends the old ones to `TalesForgeWeb.AdminRedirectController` (302, after sign-in). A page that moves gets a line there and a row in `admin_reorg_test.exs`.

## Money and AI spend

Sources: decision 2026-10-07 "All amounts in USD", `TalesForge.AICalls`, `docs/fly-secrets.md`.

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
- **Golden prompts stay byte-identical** unless a change is intended. The fixtures in `test/fixtures/prompts/` (one per adventure) only change on purpose: regenerate with `UPDATE_PROMPT_GOLDEN=1 mix test test/ex_tales_forge/game/prompt_golden_test.exs`, review the diff and say so in the PR.
- The strict GM and scene reply schema has no `maxLength` or `maxItems` (they disable xAI's prompt cache); caps are applied in code when the reply is parsed.
- The GM call streams (`stream: true`); the play page shows the narrative while it arrives (`TalesForge.LLM.Stream`). The GM reply has two variants by app role (`TalesForge.LLM.gm_variant/1`): production uses `lean` (no `location_name` in schema and prompt), playtest and local use `full`. No variant has `gm_notes` (dropped 2026-10-18); playtest QA reads each turn's code-layer session events on the run page instead. One prompt file serves both; `llm.ex` cuts the lean parts. `ai_calls` stores `ttft_ms` and `narration_variant`.
- Only the scene and GM calls share the session's `x-grok-conv-id`; persona, scorer, intent and fact-extraction calls use `<session>:<purpose>`.
- Prompt files are content: a code change must not alter their text by accident.

## Environments and deploys

Sources: `docs/environments.md`, `docs/infrastructure.md`, decision 2026-10-06 "tales-forge.ai stays on Netlify for now".

- Production: Fly app `tales-forge` ([tales-forge.fly.dev](https://tales-forge.fly.dev)). Playtest: `tales-forge-playtest` ([tales-forge-playtest.fly.dev](https://tales-forge-playtest.fly.dev)), no longer deployed automatically (hobby mode; `playtest.yml` is started only by hand). Region `arn`. Each app has its own secrets and its own xAI key.
- **Deploy lanes** (decision 2026-10-09 "A fast deploy lane for admin work"): a merge whose changed files, and all files changed since the commit production runs (tag `deployed/production`), are on the `[admin]` list in `.github/deploy-lanes.txt` (surveys, costs, playtest admin pages, `/team`) deploys **straight to production** automatically. A dependency bump that fixes a published advisory takes the **security lane** (decision 2026-10-11, relaxed 2026-11-23): only `mix.lock` (and `mix.exs` dep pins) changes, every changed package is an existing Hex package (major version bumps are allowed; a PR that adds or removes a package, or uses a git ref, goes to Fredrik's merge list), the PR has the label `security` or the title prefix `security:` plus an advisory id, and CI is green. `security-lane.yml` merges it, and `deploy-lanes.yml` deploys production for that sha through the unprotected `production-security` environment at all hours, smokes production, and rolls back on failure (`docs/DEPLOY-FLY.md`, "Security lane"). Normal deploys keep the `production` reviewer gate. Anything else, including a mixed PR, is the normal lane: a founder's Approve ships it to production. The lane is in the "Deploy lanes" run summary. Keep admin work in admin-only PRs; touching the router, shared CSS/JS, config or game code makes it normal. Game and shared code must never depend on `[admin]` files (`mix deploy.check_boundaries`, CI). Credo strict runs on admin files too (since 2026-10-11); the `@spec` check covers the backfilled files listed in `.credo.exs`.
- **`tales-forge.ai` stays on Netlify** until the Fly app replaces it. No environment gets Fly certificates or DNS changes; **deploys are verified on the `fly.dev` apps**.
- The code docs (this site) are built in the Docker builder stage and served at `/admin/code-docs` on both apps, behind the sign-in.
- Manual `fly deploy` (`docs/DEPLOY-FLY.md`) is only a fallback when Actions is down, and needs Fredrik's OK like any deploy.

## Removed — do not bring back without a decision

- **Ash** (`ash`, `ash_postgres`, `ash_phoenix`, igniter) and the authoring tables, 2026-10-07 ([#47](https://github.com/whyse-ab/ex-tales-forge/pull/47)).
- **Email magic-link sign-in** and the `ADMIN_EMAILS` allowlist, 2026-10-07 ([#54](https://github.com/whyse-ab/ex-tales-forge/pull/54)).
- **`jido_ai`**: the unused dependency was dropped (module audit, `docs/module-audit-2026-10-07.md`). LLM calls go through `TalesForge.LLM` only.
- GM bookkeeping fields: the GM no longer returns `state_updates`, `overlay_deltas` or `new_facts`; the server owns state, and with `WORLD_AGENTS` on, facts are read from the narration after the turn (`TalesForge.World.Extract`).

## Elixir coding guidelines

### Docs, types and tests (mandatory)

Humans may need to understand the code one day, including code written by bots. The full standard is `docs/coding-standards.md` (decision 2026-10-07 "Coding standards: documented, typed, tested, enforced in CI").

- `@moduledoc` on every module (`@moduledoc false` only for real internals): what it is for and how it fits in. Credo checks it.
- `@doc` on every public function (`@doc false` if public only for tests): what it returns and when it fails. Add a doctest where an example helps and the function is pure. `test/ex_tales_forge/coding_standards_test.exs` checks the backfilled modules.
- `@spec` on every public function, checked by **Dialyzer** (`mix dialyzer`). Structs get a `@type t`. Credo `Readability.Specs` enforces presence for the backfilled files listed in `.credo.exs`. An accepted Dialyzer warning goes in `.dialyzer_ignore.exs` with a reason (empty today).
- **Credo strict** (`mix credo --strict`) and `mix format`, no new issues.
- **ExDoc**: `mix docs` must build without warnings (CI runs `mix docs --warnings-as-errors`).
- **Tests for every change**; a bug fix gets a test that fails without it. `mix test --cover` fails below the threshold in `mix.exs`; raise it as coverage grows, never lower it to pass.
- **CI enforces all of this** in two required jobs: **Test** (compile with warnings as errors, format, Credo, tests with coverage, docs, `mix hex.audit`) and **Dialyzer**.
- Module docs describe current behaviour, not where the code came from or how it used to work; history goes to `docs/`.
- Older modules are backfilled when you touch them; then add them to the lists above.

### Formatting

- Run `mix format` before every commit; [.formatter.exs](https://github.com/whyse-ab/ex-tales-forge/blob/main/.formatter.exs) is authoritative (Phoenix, Ecto, LiveView HEEx).
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
     :ok <- NPC.seed_session(session) do
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
`mix intent.eval` takes `TYPESAFE_INTENT_PLAYTEST_API_KEY` first (then `TYPESAFE_INTENT_API_KEY`, `TYPESAFE_API_KEY`) so dev eval runs bill to the playtest key. Tests never read these env vars: `config :jev, :api_key` is `nil` in test and tests set it with `Application.put_env/3`.

### Two-tier LLM

Each turn runs Tier 1 intent extraction (heuristic first, else a small-model LLM call at temperature 0) then Tier 2 storytelling (Grok). The GM sees the validated `PlayerAction` with a short sanitised quote of the player's words (`overall_intent`, at most 500 characters), not the full raw message.

| Setting | Default | Purpose |
|---------|---------|---------|
| `XAI_MODEL` | `grok-4.20-0309-non-reasoning` | Fast non-reasoning Grok for all tiers |
| `TIER1_MODEL`, `TIER2_MODEL` | unset (`XAI_MODEL`) | Per-tier model override |
| `TIER1_MAX_TOKENS` | `400` | Intent JSON cap |
| `TIER2_MAX_TOKENS` | `700` | GM narration cap |
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
3. `GameSessions.submit_message/3` — the intent step (Jev, or the heuristic); returns `{:error, :needs_scene}` if scene pending
4. `TalesForge.Workers.ProcessTurn` — Tier 2 GM + mechanics
5. PubSub `{:turn_completed, payload}` → LiveView; if travel changed location, `needs_scene: true` triggers step 1 again

## Layout

```
lib/ex_tales_forge/
  world/        # World.Instance: the one process per active session
  actions/npc/  # NPC signal handlers (turn events in, Intentions out)
  game/         # intent, mechanics, scene_processor, turn_processor
  workers/      # Oban ProcessScene, ProcessTurn
  schemas/      # Ecto runtime schemas
priv/rules/     # Markdown rulebook (global; packs may carry their own rules/)
priv/prompts/   # LLM system prompts
priv/adventures/ # adventure packs: places, NPCs, rules, extensions, variants
```

## Playtest agent (`/play_test`)

After code changes, run a live playthrough to verify intent extraction and GM responses:

```bash
mix phx.server   # terminal 1
mix e2e.smoke    # terminal 2
```

See [`.grok/skills/play-test/SKILL.md`](https://github.com/whyse-ab/ex-tales-forge/blob/main/.grok/skills/play-test/SKILL.md). Reports land in `priv/playtest/reports/`.