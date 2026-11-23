# Tales Forge in hobby mode: plan (2026-11-21)

Drafted by Case from read-only research. Fredrik made his decisions on 2026-11-21 (see below). Nothing in this document has been carried out yet.
Sources: `whyse-ab/ex-tales-forge` (main, cloned 2026-11-21), `whyse-ab/team` (`bots/*/routines`), GitHub API, public `/health` and the Tales Forge board API. **The Fly login on the box has expired**, so the Fly figures below are list prices from the repo docs, not invoice amounts.

## Goal
Fredrik builds and plays Tales Forge at his own pace. The only things that keep running without him are the ones that protect players' data, security and money. No cards, votes, merge lists or bot status reports.

## Decisions (Fredrik, 2026-11-21 11:36 Stockholm)
1. **Prod only.** Stop playtest.
2. **Bobby on call only.** No other bots work on Tales Forge (Case, Gentry and Slick stop).
3. **Board:** move the 57 open ideas to GitHub Issues, then archive the board.
4. **AI spending cap on prod: $5 a day.**

**Still open, for Fredrik:** which of the 7 playtest-only features to turn on in prod. Each one stays off in prod until he says so:
1. `INN_WORLD` (Tin Valley inn world)
2. `WORLD_ANTAGONIST`
3. `COMBAT_OPPOSED` (opposed combat rolls and NPC wounds)
4. `TURN_PREMISE_FIRST` (a false premise blocks the action)
5. `LOCATION_GRID` (the GM prompt describes what is on the place's grid)
6. `CHARACTER_MEMORY` (on playtest in `shadow` mode only)
7. `CODE_HEAT_MAP` (admin call-time sampling; dev tooling)

Playtest also sets `GM_MIN_DELAY_MS=1500` and `GM_REVEAL_MIN_MS_PER_CHAR=8`, which are pacing tweaks, not features.

## Work list for Bobby (in order)
Merging this PR is **not** approval for the steps below. Each Fly write, delete and workflow change needs Fredrik's go in his own words, or his merge of the PR that makes that change. Bobby is the only bot that does Tales Forge work.

| # | Step | Gate |
|---|---|---|
| 1 | `pg_dump` the playtest DB and keep the dump off Fly, then stop the playtest machines (app and DB). Turn off the automatic playtest deploy: `playtest.yml` currently also gates the security lane's smoke check before prod, so that PR has to route the lanes straight to prod | Fly write + workflow PR: Fredrik's go / merge |
| 2 | Weekly prod `pg_dump` backup (a GitHub Action with a private artifact, or another target Fredrik picks) | Workflow PR: Fredrik merges |
| 3 | Uptime alert on `https://tales-forge.fly.dev/health` that tells Fredrik when it fails | Workflow PR (or an external service): Fredrik's go |
| 4 | Set `AI_CAP_DAY_USD=5` on prod (and `AI_CAP_SESSION_USD` only if Fredrik wants one) | Fly secret write: Fredrik's go |
| 5 | Security-fix lane: replace the wait for Gentry's `qa/gentry-go` with Fredrik's approval (or drop the lane). The Security audit and the Security lane stay as they are | Workflow PR: Fredrik merges |
| 6 | Slim AGENTS.md to about one page: stack, non-negotiables, branch + PR, green CI, Fredrik merges, the deploy command. Remove the card, vote, merge-list and Case-OK rules. Delete `health-snapshot.yml` and close #600 | Workflow change: Fredrik merges |
| 7 | Export the 57 open board ideas (and the known bugs) to GitHub Issues with labels `idea`, `bug` and `next`, then archive the board (read-only, not deleted) and remove the board webhooks | Issues and board change: Fredrik's go |
| 8 | After 30 days with no need for it: delete the playtest app and DB | Delete, cannot be undone: Fredrik's go in his own words |

Before steps 1, 4 and 8, someone has to log in to Fly on the box again (the session has expired), or Fredrik makes those changes in the Fly dashboard.

## What runs today (facts)
| Item | Today | Source |
|---|---|---|
| Prod app `tales-forge` | shared-cpu-1x 1 GB, 1 machine always on, arn, bluegreen deploy; `/health` = 200 ok | `fly.toml`; curl 2026-11-21 |
| Prod DB `tales-forge-db` | self-run Fly Postgres (postgres-flex), single node, 1 GB volume | `docs/environments.md`, `docs/infrastructure-setup.md` |
| Playtest app + DB | 512 MB + swap, always on; its own DB of 512 MB with a 1 GB volume; `/health` = 200 ok. **Flags that are on only here:** INN_WORLD, WORLD_ANTAGONIST, COMBAT_OPPOSED, TURN_PREMISE_FIRST, LOCATION_GRID, CHARACTER_MEMORY=shadow, CODE_HEAT_MAP | `fly.playtest.toml` |
| Last prod deploy (normal lane) | 2026-11-03 07:28 CET, sha 3b3bc00 | `gh run list deploy-production.yml` |
| Workflows | CI (Test and Dialyzer are required), Base guard, Deploy to playtest (auto after green main), Deploy to production (manual), Health snapshot (rolling PR #600), Security audit (cron `17,47 * * * *` and when main fails), Security lane (auto-merges and deploys lock-only bumps that keep the major version), Security-fix deploy (off-hours lane, waits for Gentry's `qa/gentry-go`) | `.github/workflows/*` |
| Case-OK check and merge bot | **No workflow exists.** These are process rules in the bots' instructions only, so dropping them changes no code. | `rg` over `.github` and the team repo |
| Branch protection (main) | requires Test and Dialyzer; no required review; admins are not enforced; force push off | GitHub API |
| Open PRs | #600 Code health history (bot), #602 and #606 Gentry eval items; all mergeable | `gh pr list` |
| Board (`whyse-flow-tales-forge-prod`) | 169 cards (101 done, 57 ideas, 5 refining, 4 parked, 2 check); latest update 2026-10-27 | board API GET |
| Backups | "No backup plan for Postgres (To confirm)": only Fly's default volume snapshots | `docs/infrastructure-setup.md` gap 11 |
| AI spending caps | `AI_CAP_SESSION_USD` and `AI_CAP_DAY_USD` exist, but are **not set on prod** (off) | `docs/fly-secrets.md` |

**Team routines for Tales Forge:**
- **Case:** a status routine (replaced today by GitHub events plus a daily 09:23 summary), Pragmatic review on every merge, Weekly branch prune (Mon 08:02), Idea board wake-up.
- **Bobby:** Fly log check (08:51 and 20:51 daily), TF board wake-ups, Security-lane deploy webhook, nightly team export.
- **Gentry:** Playtest QA run (weekdays 07:13; browser QA has been paused since the sign-in broke).
- **Slick:** no routine export exists.

## Monthly costs that can be seen
| Cost | USD/month | Source |
|---|---|---|
| Fly prod app + DB | ~13–14 | `config/config.exs` TalesForge.Costs (6.95 + 6.00); `docs/environments.md` says ~$14 |
| Fly playtest app + DB | ~7.83 | same (3.84 + 3.99) |
| Domain tales-forge.ai + other hosting | SEK 2,318.75 + 400 per year (≈ SEK 227/month) | config.exs, from Fredrik 2026-10-06 |
| GitHub whyse-ab Team | 20 (5 seats, shared with Whyse) | config.exs |
| Grok Bot team bots (Case, Bobby, Gentry) | ~225, a rough estimate | config.exs, from Fredrik 2026-10-13 |
| xAI usage (prod and playtest keys) | **unknown** | check `/admin/costs` (signed in) or the xAI console |
| Fly actual invoice | **unknown** (login expired) | fly.io dashboard → Billing, org whyse-ab |
| Board app `whyse-flow-tales-forge-prod` | **unknown** | Fly dashboard |

The big lever is the bots, not Fly.

## KEEP (minimal safety)
1. **CI** (Test and Dialyzer required on main). Free, because the repo is public.
2. **Security audit + Security lane.** Pure GitHub Actions with no bot in the loop: lock-only bumps that keep the major version merge and deploy themselves after the smoke check. **Change:** the Security-fix lane needs Gentry's GO, so either drop it or route it to Fredrik.
3. **Backups:** add a weekly `pg_dump` of prod (a GitHub Action that keeps a private artifact, or a manual dump to Fredrik's machine). Today there is none beyond snapshots.
4. **Uptime alert:** a free external check on `https://tales-forge.fly.dev/health` (a GitHub Actions cron or UptimeRobot) that emails Fredrik. It replaces Bobby's twice-daily log check.
5. **Cost ceiling:** `AI_CAP_DAY_USD=5` on prod (decided), plus a monthly limit in the xAI console if Fredrik wants one.

## DROP or archive (all reversible unless noted)
| Item | How | Reversible? |
|---|---|---|
| Card board process and board wake-ups | Stop using it; export the 57 open ideas to `docs/future-ideas.md` or GitHub issues; remove the webhooks | Yes, while the board app exists. Deleting the board app/DB is **not** reversible, so export first. |
| Founder votes, merge lists, Case-OK, bot-merge lane | Rule change in AGENTS.md/docs | Yes |
| Health snapshot + PR #600 | Disable or delete `health-snapshot.yml`, close #600 | Yes (git history) |
| Eval PR churn (#602, #606) | Merge once as the final batch, or close | Yes |
| Base guard | Keep or delete; it costs nothing | Yes |
| Team routines (above) | Pause first, delete after 30 days | Pausing: yes |
| Gentry daily QA, Slick creative work | Pause | Yes |
| `docs/decisions.md` ceremony (1,662 lines) | Freeze it; Fredrik writes one-line notes only when he wants | Yes |

## Prod/playtest options
- **A. Keep both** (~$21–22/month). Safe testing before prod, but double the ops for a single player.
- **B. One environment: prod only** (saves ~$7.83/month). Test locally (`mix phx.server` against the dev DB). New features ship behind flags on prod. Before this, Fredrik decides which of the 7 playtest-only flags to turn on in prod or leave off. Stopping the playtest machines is reversible; deleting the app/DB is not (dump the DB first).
- **C. Scale prod to zero when idle** (app saves up to ~$6.95/month). Risky: the docs say waking from sleep failed on prod, and the self-run Postgres sleeps only after the app closes its connections, so the DB still costs. Not recommended without a test.

**Decided: B** (see Decisions).

## How Fredrik works solo
- A coding agent in the repo (Cursor/Claude Code) that reads AGENTS.md. Cut AGENTS.md (423 lines) to about one page: stack, non-negotiables 1–9, "branch + PR, CI green, Fredrik merges", and the deploy command.
- TODO: GitHub Issues with labels `bug`, `idea`, `next`, seeded from the board's open ideas and the known bugs (brass key false premise, untrained roll label, two-turn, hang, clarification crash).
- Light review: CI green plus Fredrik's own playthrough. A review bot only on request.

## Bot roles: options
1. **No bots for TF.** Only GitHub Actions and the uptime alert. Cheapest; Fredrik owns everything.
2. **One on-call bot (Bobby):** listens for the security-lane deploy and uptime/audit failures, reviews a PR or deploys **only when Fredrik asks**. Case, Gentry and Slick are retired from TF.
3. **Bobby on call + Case on request** for design or review, with no routines.

**Decided: option 2.** Security stays automatic, and Bobby can still fix a broken deploy on request.

The original options and migration steps were replaced by the Decisions and the Work list above.
