---
name: play-test
description: >
  Run a live playthrough against Tales Forge (ex-tales-forge) after code changes.
  Use when the user runs /play_test, /play-test, or asks to smoke-test
  a session playthrough, check response times, or verify intent extraction.
---

# Play Test (`/play_test`)

Run a **live** playthrough against the Phoenix server with real LLM calls.

## Parse arguments

- Slash command: `/play_test` or `/play_test tavern_smoke`
- Default scenario: `tavern_smoke` (built into `mix e2e.smoke`)

## Preflight

1. **Repo root** — run commands from the ex-tales-forge directory.

2. **Environment** — `mix dev.check`
   - `[ok] .env found`
   - `[ok] PostgreSQL connected`
   - `[ok] XAI_API_KEY set (...)` and `LLM provider: xai`
   - If any check fails, stop and fix before playtesting.

3. **Server health** — Phoenix on port 4000:
   ```bash
   curl -sf http://localhost:4000 > /dev/null && echo "server up"
   ```
   - If down, start:
     ```bash
     mix phx.server
     ```
   - If port busy: `lsof -ti :4000 | xargs kill -9` then restart.

4. **API key** — confirm `.env` has `XAI_API_KEY`. Warn if `LLM_PROVIDER=mock` — playtest should use `GM source: api`.

## Run playtest (automated)

With the server running in another terminal:

```bash
mix e2e.smoke
```

This runs the tavern smoke scenario (3 turns) via `GameSessions`, waits for Oban LLM jobs, and writes `priv/playtest/reports/e2e-smoke.json`.

Expect stdout:

```
E2E smoke: PASS
  step 1: PASS (...ms)
  step 2: PASS (...ms)
  step 3: PASS (...ms)
```

## Run playtest (manual browser check)

Optional UI verification at http://localhost:4000:

1. Click **Start new session**
2. Play the same actions as `mix e2e.smoke`
3. Confirm play header shows **`GM source: api`** after the first turn

## Report results

1. Read `priv/playtest/reports/e2e-smoke.json` and latest `e2e-smoke.md` if present.
2. State **PASS** or **FAIL** clearly.
3. For each failed step, show `issues`, `latency_ms`, and `narrative_preview`.
4. Grep server logs for `[error]`, `[warning]`, `turn processor failed`.
5. Persona check against `PRODUCT.md` (Hawk / Paul / Lotta / Lars; not Ronny):
   - Did the narration dump dice, DCs, or skill names? (Paul fails)
   - Did failure get softened into a win? (Hawk fails)
   - Was the world/character thin or generic? (Lotta fails)
   - Did the scene stall with no adventure pressure? (Lars fails)
   - Did the GM optimize for loot, levels, or "winning"? (Ronny — that is a miss)

6. Suggest which layer broke:
   - **intent** → `lib/ex_tales_forge/game/intent.ex`
   - **GM / narrative** → `lib/ex_tales_forge/llm.ex`, `priv/prompts/gm_system.txt`
   - **mechanics** → `lib/ex_tales_forge/game/mechanics.ex`, `action_handler.ex`
   - **latency** → model config, Oban queue, Ollama retry noise (set `TIER1_MODEL=xai/grok-4.3`)

## Do not

- Substitute `mix test` for this skill — tests use inline Oban and may hit mock LLM paths.
- Reuse an old session after pulling code changes.
- Fail silently when `mix dev.check` reports missing API key.

## Future enhancements

Port from [text-forge/backend/app/playtest/](text-forge/backend/app/playtest/):

- [ ] `priv/playtest/scenarios/*.yaml` — multiple scenarios
- [ ] `--judge` mode using LLM to score narrative quality
- [ ] Intent debug exposure on turn responses (like text-forge `PLAYTEST_EXPOSE_INTENT`)

Reference: `text-forge/.grok/skills/play-test/SKILL.md`