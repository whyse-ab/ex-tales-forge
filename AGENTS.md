# ex-tales-forge — Agent Rules

Read `docs/principles.md` first; the north star is ETC, Easy To Change. These
rules are for anyone, human or bot, who changes this repo. Details live in
`docs/` (`docs/decisions.md`, newest first, and `docs/coding-standards.md`).

Tales Forge is in hobby mode (`docs/hobby-mode.md`): Fredrik builds at his
own pace. Bobby is the only bot that works on this repo, and only when
Fredrik asks or an on-call alert fires.

## Stack

- **UI:** Phoenix LiveView + Tailwind
- **Runtime:** OTP. One `TalesForge.World.Instance` GenServer per active session.
- **Persistence:** Ecto + PostgreSQL
- **Jobs:** Oban (`default`, `llm`)
- **AI:** xAI Grok for prose (`TalesForge.LLM`); TypeSafe Jev (Hex `jev`) for typed answers from free text
- **Content:** pack files under `priv/` (`adventures`, `npcs`, `rules`, `prompts`, `characters`)
- **Auth:** Sign in with GitHub against the `whyse-ab/tales-forge` team. `/health` is public.

## How changes land

1. **Branch + pull request.** Never commit to `main` directly. Never force-push and never push to `main`.
2. **CI must be green.** The required checks on `main` are **Test** and **Dialyzer**.
3. **Fredrik merges.** Bots do not merge, except the security lane (lock-only Hex bumps of existing packages, majors allowed; a PR that adds or removes a package, or uses a git ref, goes to Fredrik's list).
4. **Production deploy**, after Fredrik's OK for that sha:

   ```bash
   gh workflow run deploy-production.yml -R whyse-ab/ex-tales-forge -f sha=<full 40-character sha>
   ```

   The security lane deploys through the `production-security` environment at all hours. Normal deploys use the `production` environment and its reviewer gate.
5. **Fly writes** (secrets, scale, stop, delete) need Fredrik's own OK in chat. Deletes are a separate ask. Secret names only, never values (`docs/fly-secrets.md`).

```bash
git fetch origin
git checkout -b feature/<short-name> origin/main
# ... work, commit ...
git fetch origin && git rebase origin/main
git push -u origin feature/<short-name>   # then open a PR
```

## Non-negotiables

1. **Plain Ecto + Repo everywhere.** Ash was removed ([#47](https://github.com/whyse-ab/ex-tales-forge/pull/47)). Don't add a second data layer without a decision.
2. **Call-type rule** (`docs/call-types.md`): structured in + structured out = Elixir; unstructured in + structured out = Jev; prose = LLM. Use the LLM last, with the smallest input possible.
3. **One Character type** for player characters and NPCs. Don't add a separate PC or NPC model.
4. **Intent before the GM.** One Jev call (`INTENT_JEV=on`), Elixir heuristic as fallback. The GM gets a typed `PlayerAction` plus a short quote (at most 500 characters). The raw message never goes to the GM.
5. **The server owns mechanics.** It rolls dice and applies LP, inventory, coins, prices and time. The LLM narrates and never invents mechanics.
6. Important authored state stays human-readable in `priv/`.
7. LLM replies use structured JSON with a strict schema.
8. Turn history is auditable: every turn is a `Turn` row.
9. **Secret names only, never values**, in code, docs, commits, PRs, logs and chat.

The seven playtest-only flags (`INN_WORLD`, `WORLD_ANTAGONIST`, `COMBAT_OPPOSED`, `TURN_PREMISE_FIRST`, `LOCATION_GRID`, `CHARACTER_MEMORY`, `CODE_HEAT_MAP`) stay **off on production**. Keep the code. Do not flip them without Fredrik's OK.

## Standing rules

- **No unauthenticated AI calls.** No unauthenticated route, LiveView event or endpoint may start an AI call.
- **AI cap and key changes need Fredrik's OK.** Changing a cap (`AI_CAP_SESSION_USD`, `AI_CAP_DAY_USD`, `AI_CAP_PERSONA_RUN_USD`), or adding an AI key, needs Fredrik's OK.
- **Golden prompts** stay byte-identical unless a change is intended. Regenerate with `UPDATE_PROMPT_GOLDEN=1 mix test test/ex_tales_forge/game/prompt_golden_test.exs`, review the diff and say so in the PR.
- **Admin boundary.** Game and shared code must never depend on `[admin]` files (`mix deploy.check_boundaries`, CI).
- **No Fly DNS or cert changes.** `tales-forge.ai` stays on Netlify until the Fly app replaces it. No environment gets Fly certificates or DNS changes; deploys are verified on the `fly.dev` apps.
- **Don't bring back GM `state_updates`, `overlay_deltas` or `new_facts`.** The server owns state.
- **Record decisions in `docs/decisions.md`**, newest at the top.

## Quality

Before you finish a code change: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, and `mix test`. Full coding rules are in `docs/coding-standards.md`. UI copy and reports use "confidence", not "unsure" (decision 2026-10-10; `CONTRIBUTING.md`).

Do not bring back Ash, email magic-link sign-in, or `jido_ai` without a decision.
