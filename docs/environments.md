---
title: Environments and how changes reach production
updated: 2026-11-23
---

# Environments and how changes reach production

Status 2026-11-23: **production** is live. **Playtest** is still up, but a merge to `main` no longer deploys it automatically (hobby mode, [hobby-mode.md](hobby-mode.md) step 1; `playtest.yml` is started only by hand). **Production** for a normal merge is a separate, manual step after Fredrik has OK'd it. Admin-only merges go straight to production ([decision 2026-10-09](decisions.md#2026-10-09-a-fast-deploy-lane-for-admin-work), [#107](https://github.com/whyse-ab/ex-tales-forge/pull/107), merged; see [Deploy lanes](#deploy-lanes-admin-work-goes-straight-to-production)). Lock-only bumps that fix a published advisory take the security lane ([decision 2026-10-11](decisions.md#2026-10-11-security-bump-lane); see [Security lane](#security-lane-advisory-fixes-ship-without-a-founder-ok)). PR previews are decided but not built yet.

## Branches

- `main` is the branch production runs a commit of. Nobody pushes to it directly; everything goes in through a pull request. `main` is protected: the required CI checks **`Test`** and **`Dialyzer`** must both pass before anything lands on it. Playtest, while its machines are still up, can be deployed from `main` by hand.
- Each change gets a short-lived branch (`feature/...`, `fix/...`), a PR, and is deleted after merge.
- There is no long-lived `dev` or `staging` branch.

## The three environments

| | Production | Playtest | PR preview |
|---|---|---|---|
| Fly app | `tales-forge` | `tales-forge-playtest` ([tales-forge-playtest.fly.dev](https://tales-forge-playtest.fly.dev)) | `tales-forge-pr-<number>` (its own app) |
| App machine | shared-cpu-1x, 1 GB, 1 machine always on | shared-cpu-1x, 512 MB plus 512 MB swap, 1 machine always on | Small, created per PR |
| Database | `tales-forge-db` (own Fly Postgres) | `tales-forge-playtest-db`: own Fly Postgres (postgres-flex 18), single node, shared-cpu-1x 512 MB, 1 GB volume, always on | A database per PR **on the playtest cluster** `tales-forge-playtest-db`, dropped with the app |
| Runs | A commit of `main`, deployed by the lane (`deploy-lanes.yml` for admin and security; "Deploy to production" by hand for normal) | `main`, deployed only by hand ("Deploy to playtest") | The PR's branch |
| Who uses it | Players, admins | Persona bots (self-play) and a few invited testers | Whoever reviews the PR |
| Admin data that lives only here | Founder surveys (`/admin/survey`, `/admin/surveys/*`) | Playtest runs (`/admin/playtest/*`) | Not built; its app name has no "playtest", so it would act as production (revisit when previews are built) |
| Lifetime | Always on | Long-lived, always on | Created when the PR opens, destroyed when it closes |
| AI key | Production `XAI_API_KEY` | Its own `XAI_API_KEY`, so bot cost is counted separately | None: mock narration |
| Status | Live | Live since 2026-10-06 | Decided, not built |

Region is `arn` (Stockholm) for all three. The `tales-forge.ai` domain stays on Netlify. No environment gets Fly certificates or DNS changes.

## How a change gets to production

Hobby mode, 2026-11-23 ([hobby-mode.md](hobby-mode.md)): production is the live environment. Playtest is no longer deployed automatically.

1. Push a branch and open a PR. GitHub Actions runs the two required jobs: **`Test`** (compile with warnings as errors, format check, Credo strict, the code health ratchet `mix health.check`, tests with coverage, the docs build and `mix hex.audit`) and **`Dialyzer`**.
2. Later (not built yet), a preview app also starts for the PR, with its link posted on the PR.
3. When the checks are green and the change is reviewed, merge to `main` (Fredrik's OK).
4. On `main`, Actions (`.github/workflows/ci.yml`) runs `Test` and `Dialyzer` again. CI itself deploys nothing.
5. **Playtest, by hand only.** `.github/workflows/playtest.yml` ("Deploy to playtest") is started from the Actions tab (optionally with a `sha`). It needs the Actions secret `FLY_API_TOKEN_PLAYTEST`. Migrations run first (`/app/bin/migrate`), and only one playtest deploy runs at a time.
6. **Lanes, automatically.** After every green CI run on `main`, `.github/workflows/deploy-lanes.yml` picks the deploy lane. Admin and security merges go straight to production. A normal merge waits for the next step.
7. **Production, by hand for the normal lane, after Fredrik's OK.** The "Deploy to production" workflow (`.github/workflows/deploy-production.yml`) is started for that commit:

   ```bash
   gh workflow run deploy-production.yml -R whyse-ab/ex-tales-forge -f sha=<full 40-character sha>
   ```

   A first job refuses the run unless the sha is on `main` and its `Test` and `Dialyzer` checks passed, and warns when no successful playtest deploy of that sha is found. The deploy job then runs in the GitHub environment **`production`** for normal and admin deploys (the required reviewer is the gate). The security lanes (`security`, `security-fix`, `security-rollback`) always use **`production-security`** (no reviewer, `main` only), at all hours. The job deploys exactly that commit to `tales-forge`, with migrations first (`/app/bin/migrate`). Only one prod deploy runs at a time, and a running deploy is never cancelled. It uses `FLY_API_TOKEN`, an environment secret on both environments. A bot starts this workflow only on Fredrik's explicit OK for that sha. Once a required reviewer (Fredrik) is set on the `production` environment (repo Settings → Environments), the job also waits for that approval; until then the manual start is the gate.

A manual `fly deploy` is the fallback when Actions is down. It is the same command CI runs; see `docs/DEPLOY-FLY.md` in ex-tales-forge. For playtest: `fly deploy --remote-only --depot=false -c fly.playtest.toml -a tales-forge-playtest --ha=false`.

## Deploy lanes: admin work goes straight to production

Decision 2026-10-09 ([decision log](decisions.md#2026-10-09-a-fast-deploy-lane-for-admin-work)), built in [#107](https://github.com/whyse-ab/ex-tales-forge/pull/107), merged 2026-10-09 (main `2f1c909`). Until the next production deploy through the workflow sets the `deployed/production` tag, every merge takes the normal lane.

| Lane | When | Playtest | Production |
|---|---|---|---|
| **Admin** | Every file the merge changed **and** every file changed since the commit production runs is on the `[admin]` list in ex-tales-forge `.github/deploy-lanes.txt` | Manual only | Automatic, straight to production: no Gentry/batch gate, no prod OK |
| **Security** | A lock-only dependency bump of existing Hex packages (major version bumps allowed; adding or removing a package, or a git ref, is not this lane) that fixes a published advisory, with green CI ([Security lane](#security-lane-advisory-fixes-ship-without-a-founder-ok)) | Manual only | Automatic, through `production-security` at all hours; smoke check on production, rollback on failure; Bobby tells the founders |
| **Security fix** | Off-hours only: a fix for a high or critical dependency advisory with an OSV id, label `security-fix` ([Off-hours security fixes](#off-hours-security-fixes)) | Manual only; Gentry plays it if playtest is deployed by hand | Automatic after Gentry's `qa/gentry-go` and the guard; smoke check, rollback on failure |
| **Normal** | Anything else: game engine code (`Game.*`, intent, world, NPCs, rules, packs), shared code (sign-in and the signed-out `/internal/*` endpoints, Repo and migrations, config, `AICalls`, `mix.exs`/deps, the router, shared CSS/JS, CI), docs, unknown files, a mixed merge | Manual only | A founder's Approve ships it (step 7); `production` reviewer gate |

- **The admin list** (one place, `.github/deploy-lanes.txt`): the founder survey (`Surveys`, `Survey.*`, the survey admin LiveViews, components and CSV export, `priv/surveys/`), the costs page (`Costs`, `Costs.*`, `CostsLive`; not the signed-out `GET /internal/costs` controller), the playtest admin pages (`PlaytestLive`, `Playtest.Summary`, `Playtest.CharacterChanges` and its components, `priv/playtest/summary/`; not the persona runner, scorers or personas), and the founders' pages (`TeamPage`, `TeamLive`, `TeamPresentationLive`, the live PR feed `PrFeed` and `TeamPrFeedLive`, the `team_*` components, `team_hooks.js`, `priv/team/`, `priv/static/images/team/`), each with its tests.
- **How the lane is picked:** after a green CI run on `main`, "Deploy lanes" diffs the merge against its parent and against the tag **`deployed/production`** (the commit production runs; every production deploy moves it). Both must be admin-only. So an admin merge never carries an earlier game merge that still waits for a founder's Approve. With no tag yet, or a rollback, the lane is normal. The lane and the files that decided it are in the run summary.
- **The admin lane's production deploy** is the "Deploy to production" workflow called from deploy-lanes.yml: the same "Verify commit" job (sha on `main`, `Test` and `Dialyzer` green), then, one deploy at a time, it deploys only if the commit is **still the tip of `main`** and production hasn't moved since the lane was picked. Otherwise it skips with a notice.
- **Boundary:** game code, and shared code other than the router and the application, must never depend on admin modules. CI's `Test` job checks it (`mix deploy.check_boundaries`).
- **Gates:** admin files get format and tests only (no Credo, so no `@spec`/`@doc` demands); game and shared code keep Credo strict, specs and Dialyzer. `Test` and `Dialyzer` stay the required checks ([Coding standards](coding-standards.md)).
- Keep admin work in admin-only PRs: a `/team` PR that also adds a route or touches the shared CSS is normal.

## Security lane: advisory fixes ship without a founder OK

Decision 2026-10-11 ([decision log](decisions.md#2026-10-11-security-bump-lane)), built in [ex-tales-forge #171](https://github.com/whyse-ab/ex-tales-forge/pull/171) (open). Details: `docs/DEPLOY-FLY.md` in ex-tales-forge, section "Security lane".

A PR takes the security lane when all four rules pass (`TalesForge.DeployLanes.Security`):

1. It changes only `mix.lock`, and optionally the version requirements of deps in `mix.exs`.
2. Every changed package is an existing Hex package. Major version bumps are allowed. A PR that adds or removes a package, or uses a git ref, goes to Fredrik's merge list.
3. It has the label `security` or the title prefix `security:`, and an advisory id (CVE, GHSA or EEF-CVE) in the title or body.
4. CI is green (`Test` and `Dialyzer`).

When a rule fails, the PR takes the normal lane. The run summary shows PASS or FAIL for each rule.

- **Find, every hour:** "Security audit" (`security-audit.yml`) runs `mix hex.audit` and `mix deps.audit`. For each advisory it runs `mix deps.update` on that package and opens a PR `security: <advisory id>: …` with the label, including when the fix is a major bump of an existing Hex package. High and critical advisories are handled at any hour: the same job runs day and night. A fix that adds or removes a package, uses a git ref, or needs a code change goes to Fredrik's merge list.
- **Merge:** "Security lane" (`security-lane.yml`) runs after the PR's CI and squash-merges it for exactly its head sha.
- **Deploy:** "Deploy lanes" checks the rules again on the merge, and also that production gets nothing else (everything since `deployed/production` is a lock bump of existing Hex packages — major bumps allowed — or an admin file). Then production for that sha through `production-security` at all hours, with the same guards as the admin lane, a smoke check on production (`/health`, the sign-in page, a LiveView mount; no game turn, because a turn calls the LLM), and a rollback to `deployed/production-previous` if the smoke check fails.
- **Tell:** after the production deploy, Bobby gets a signed webhook (`SECURITY_LANE_WEBHOOK_URL`) and tells Gentry and the founders through Case.
- **Fredrik's merge list** (not the auto lane) for a PR that adds or removes a package, uses a git ref, needs a code change, or changes player-facing behaviour. Major version bumps of existing Hex packages merge and auto-deploy on green CI. Normal deploys keep the `production` reviewer gate.

## Off-hours security fixes

Fredrik, 2026-10-27: outside working hours (Mon-Fri 08:00-18:00 Europe/Stockholm) bots may merge and deploy security-fix PRs, in this lane only (AGENTS.md rule 2 carve-out). Only a dependency advisory with an OSV id qualifies; a flaw in our own code gets containment only and waits for the founders.

- **Guard** (`TalesForge.DeployLanes.SecurityFix`, always run from `main`'s code, never the PR's): `main` only, outside working hours, `Test` and `Dialyzer` green on the exact sha, at most 10 files and 300 changed lines, no `[founder]` path from `.github/deploy-lanes.txt` except `mix.exs`/`mix.lock`, and a high or critical advisory (hex.pm, the data `mix hex.audit` reads, confirmed by its OSV record) on a changed package at the base version that is gone at the head version.
- **Merge:** "Security lane" (`security-lane.yml`) checks the guard plus the label `security-fix` and squash-merges the PR's head sha.
- **Playtest and Gentry:** playtest is no longer deployed automatically, so this lane waits until playtest is deployed by hand and Gentry is happy. The `gentry-qa` GitHub App then posts the commit status `qa/gentry-go` = success on that sha (only that App's login, the repo variable `GENTRY_GO_LOGIN`, counts). Replacing that Gentry wait is a later hobby-mode step.
- **Deploy:** that status starts "Security-fix deploy" (`security-fix-deploy.yml`). It re-checks the guard against production (`deployed/production`) at deploy time, plus Gentry's GO and that every merge since production is a `security-fix` PR, then deploys with lane `security-fix` (environment `production-security`, no reviewer).
- **Smoke check and rollback:** a smoke check on production; when it fails, production goes back to `deployed/production-previous` (lane `security-rollback`). Bobby gets a signed webhook either way (`security_fix.deployed`, `.smoke_failed` or `.rolled_back`).

## What needs Fredrik's OK

- Merging anything to `main` that is not on an automatic lane (an admin-only merge, and a qualifying security bump, still go to production without a further click, [#107](https://github.com/whyse-ab/ex-tales-forge/pull/107)).
- Every normal-lane production deploy: starting "Deploy to production" for a sha. Admin-lane, security-lane and off-hours security-fix deploys ship without that start.
- Creating or deleting Fly apps, databases, volumes, deploy tokens and GitHub secrets.
- Anything that adds cost, such as a bigger machine, an always-on playtest, or Managed Postgres.
- Inviting playtesters and giving out admin access (`ADMIN_EMAILS`, `ADMIN_GITHUB_TEAM`).

## Invited testers (later)

The founders are the first testers: they sign in to playtest with GitHub through the `whyse-ab/tales-forge` team, like production. Since ex-tales-forge PR #54 ([decision 2026-10-07](decisions.md#2026-10-07-github-team-sign-in-is-the-only-login-on-production-and-playtest)) that is the only login on both apps, and every page needs it. Email sign-in is gone. Outside testers will need a new decision (team membership or another login).
- A new AI key, or raising the spending cap on one.

## Costs (estimates, 2026-10-06)

Fly list prices for `arn` per 30 days: shared-cpu-1x is $2.28 with 256 MB, $3.84 with 512 MB and $6.95 with 1 GB. Volumes cost $0.15/GB-month, and a stopped machine costs only $0.15/GB-month of its disk image, which is a few cents for our apps. These are Fly's prices for the machines; AI usage is billed separately by xAI.

| Environment | Setup | Estimate per month |
|---|---|---|
| Production (today) | App 1 GB always on; DB 1 GB always on plus a 1 GB volume | ~$14 |
| Playtest app (live) | `tales-forge-playtest`: shared-cpu-1x 512 MB, 1 machine always on (swap is free) | ~$3.84 |
| Playtest DB (live) | `tales-forge-playtest-db`: shared-cpu-1x 512 MB always on ($3.84) plus a 1 GB volume ($0.15) | ~$3.99 |
| PR previews (not built) | About 4 PRs a month, 3 days each: own small app plus a database on the playtest cluster | ~$1.50 |
| **New cost in total** | Playtest ~$7.83 plus previews | **~$8 now, ~$9.50 with previews** |

Total new cost stays under $15/month in every option. Sources: [Fly pricing](https://fly.io/docs/about/pricing/), [Fly billing](https://fly.io/docs/about/billing/).

The admin costs page (`/admin/costs`, ex-tales-forge PR #28) shows these fixed costs next to actual AI spend for both environments. Its figures come from one config block, `config :ex_tales_forge, TalesForge.Costs` in ex-tales-forge's `config/config.exs` (USD per month or SEK per year); update it when the numbers here change. Domain and other hosting figures (SEK/year, from Fredrik 2026-10-06) are also in that block.

Why always on: production runs always on because waking from sleep failed there. The 256 MB database stalled under load in production. Our Fly Postgres type is no longer maintained by Fly, and its sleep mode only kicks in once the app has stopped and closed its connections. So playtest's app and database never sleep either.

Memory: at 512 MB with no swap, the playtest app was killed for running out of memory during boot. With 512 MB of swap it boots in about 25 s and runs with roughly 165 MB swapped out. If it feels slow, moving to 1 GB adds about $3/month.

## Secrets per environment (names only)

Values live in Fly secrets or GitHub Actions secrets, never in the repos.

**Production** (Fly app `tales-forge`): `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `ADMIN_EMAILS`, `ADMIN_GITHUB_TEAM`, `GITHUB_DOCS_TOKEN`, `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, `XAI_API_KEY`; later `MAIL_ADAPTER`, `RESEND_API_KEY`, `ADMIN_MAIL_FROM`. See [fly-secrets.md](fly-secrets.md).
GitHub environment secret (on `production` and `production-security`): `FLY_API_TOKEN`, a deploy token that only works on `tales-forge`.
GitHub Actions secrets for the security lane (not set yet, [#171](https://github.com/whyse-ab/ex-tales-forge/pull/171)): `SECURITY_BOT_APP_ID` and `SECURITY_BOT_APP_PRIVATE_KEY` (or `SECURITY_BOT_TOKEN`), and the optional `SECURITY_LANE_WEBHOOK_URL` and `SECURITY_LANE_WEBHOOK_KEY`. See [fly-secrets.md](fly-secrets.md#github-actions-secrets-for-the-security-lane).

**Playtest** (Fly app `tales-forge-playtest`, live). All values are its own, never copied from production, except the read-only `GITHUB_DOCS_TOKEN`:

| Name | Status |
|---|---|
| `DATABASE_URL` | Set (by `fly postgres attach tales-forge-playtest-db`) |
| `SECRET_KEY_BASE` | Set (newly generated) |
| `ADMIN_EMAILS` | Set (fredrik@whyse.se); unused since PR #54 |
| `ADMIN_GITHUB_TEAM` | Set (`whyse-ab/tales-forge`): the founders sign in with GitHub, same check as production |
| `XAI_API_KEY` | Set, live: a separate playtest key |
| `PHX_HOST` | Not a secret here: `tales-forge-playtest.fly.dev` is in `fly.playtest.toml` |
| `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` | Set, from a second OAuth app with the playtest callback |
| `GITHUB_DOCS_TOKEN` | Set, same read-only token as production; needed for the team check |
| `MAIL_ADAPTER`, `RESEND_API_KEY`, `ADMIN_MAIL_FROM` | Not set (production has none either). Not needed: sign-in is GitHub team only (PR #54) |

GitHub Actions secret: `FLY_API_TOKEN_PLAYTEST`, a deploy token for `tales-forge-playtest` only (set).

**PR previews** (decided, not built): each preview is its own Fly app with its own database on the playtest cluster `tales-forge-playtest-db`. App and database are destroyed when the PR closes. Secrets: `DATABASE_URL` (set when the database is attached), and `SECRET_KEY_BASE`, newly generated for each preview by the workflow and never stored anywhere else. `PHX_HOST` is the preview's own `.fly.dev` name. Optional: `ADMIN_EMAILS`. No AI key, so the game master gives mock narration, and no mail key.
GitHub Actions secret: a Fly token that can create and destroy apps, which is broader than a deploy token (see the open decisions).

## Decided (2026-10-06)

- Playtest keeps 1 machine always running, and so does its database (~$8/month in total).
- Previews get their own app and a per-PR database on the playtest cluster, with no AI key, destroyed when the PR closes.
- `main` is protected with the required check `Test` (`Dialyzer` has since been added as a second required check; see [Coding standards](coding-standards.md)). Production deploys automatically from `main` through Actions; playtest follows right after. (Superseded 2026-10-09: playtest first, production by hand; see above.)

## Open decisions

- Whether previews live in a separate Fly organization so their app-creating token can't touch production.
- How outside testers sign in to playtest later (a separate tester list, plus a mail key). The founders already use the GitHub team.
