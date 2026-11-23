---
title: Infrastructure assets
updated: 2026-11-23
---

# Infrastructure assets

Everything Tales Forge runs on, in one place. "Login held by" says who can get in today, not who is responsible for anything. Never write secret values here; only say where they are stored.

## Now

| Asset | What it's for | Status | Cost | Login held by | Secret stored in |
|---|---|---|---|---|---|
| Domain `tales-forge.ai` | Game and admin addresses | Exists | SEK 2,318.75/year (from Fredrik 2026-10-06); on the costs page as yearly and monthly share ÷ 12, converted at the configured USD→SEK rate | Fredrik | Shared vault (todo) |
| GitHub organization `whyse-ab` | Holds `ex-tales-forge`, `tales-forge-docs`, `text-forge`; founders in one team | Created as `whyse-ab` (Team plan); ex-tales-forge and tales-forge-docs moved 2026-10-06, text-forge still under `fpahlen` | Team plan (branch protection included) | Fredrik | — |
| Fly.io account and app `tales-forge` | Hosts the game and its admin, region `arn` (Stockholm) | Live at tales-forge.fly.dev (org personal, account fredrik@whyse.se); deployed from PR #15 branch | ~$6–7/month (shared-cpu-1x, 1 GB, always on; auto-stop caused failed cold starts) | Fredrik | Shared vault (todo) |
| Postgres on Fly | Sessions, decisions, comments | Self-run Fly Postgres `tales-forge-db` (arn), attached | ~$6/month (shared-cpu-1x, 1 GB; 256 MB stalled under load. Unsupported; managed ~$38/month later if needed) | Fredrik | Fly secret `DATABASE_URL` |
| Resend | Sends sign-in links now, player mail later | Not created | Free at current volume | — | Fly secret `RESEND_API_KEY` |
| xAI API keys | AI game master | Production key live; separate playtest key live on `tales-forge-playtest` | Usage-based; the main per-session cost | Fredrik | Fly secret `XAI_API_KEY` (one per app) |
| Table `ai_calls` (each app's Postgres) | AI cost per LLM call: tokens, model, cost (micro-USD), latency, status, linked to game session and turn; feeds the playtest spending caps | Merged ([ex-tales-forge #19](https://github.com/whyse-ab/ex-tales-forge/pull/19)), created by the release migration on deploy; `capped` rows from the spending caps merged ([#20](https://github.com/whyse-ab/ex-tales-forge/pull/20)) | Free (existing Postgres) | — | — (no new secret; cost read from `XAI_API_KEY` responses) |
| Table `playtest_runs` (playtest Postgres) | One row per persona bot run: session (a bot session), persona, module, build, turn limit, turns played, status, stop reason, start and finish times, notes; game time and the persona bot's own calls, time, tokens and cost (kept apart from the game). Feeds the admin playtest report | Merged ([ex-tales-forge #23](https://github.com/whyse-ab/ex-tales-forge/pull/23)); time and persona columns merged ([ex-tales-forge #24](https://github.com/whyse-ab/ex-tales-forge/pull/24)), live since 2026-10-06; created by the release migration on deploy (also in production, where it stays empty) | Free (existing Postgres) | — | — (no secret; `PLAYTEST_RUNNER_ENABLED` turns runs on, playtest only) |
| Table `playtest_scores` (playtest Postgres) | Judge scores for a playtest run: run, judge model, rubric version, score and quoted evidence per scorecard criterion, overall, rationale. One row per scoring; the newest is shown in the admin report | Merged ([ex-tales-forge #24](https://github.com/whyse-ab/ex-tales-forge/pull/24)), live since 2026-10-06; created by the release migration on deploy (also in production, where it stays empty) | Free (existing Postgres); each scoring is one AI call, about $0.004–0.008 | — | — (no secret; scoring only runs when `PLAYTEST_RUNNER_ENABLED` is on) |
| Other hosting-related costs | Misc hosting outside the Fly machines (DNS, registrar extras and similar) | Exists | SEK 400/year (from Fredrik 2026-10-06); on the costs page as yearly and monthly share ÷ 12 | Fredrik | — |
| TypeSafe Jev (persona-affect scoring) | Numeric frustrated→delighted scores for playtest runs (session + per turn); Hex `jev`, model `jev-1.13.0` | In review (ex-tales-forge branch `jev-persona-affect`). Key on playtest only | Usage-based at TypeSafe (~$0.042/1M input); mirrored into `ai_calls` as `scorer` | Fredrik | Fly secret `TYPESAFE_API_KEY` on `tales-forge-playtest` (set 2026-10-07; not on prod) |
| Admin costs page `/admin/costs` | Read-only page for admins: AI spend per environment (production and playtest on one page) for today and this month on Stockholm time, split into game, persona and scorer with call and capped/error counts; average game cost per game session; a month-end AI projection; fixed costs (USD/month or SEK/year); USD with SEK at a fixed dated rate; a warning when playtest's fixed costs plus projected AI go over $15/month. Fixed costs, the rate and the threshold are edited in **one place**: `config :ex_tales_forge, TalesForge.Costs` in `config/config.exs` (ex-tales-forge) | Live since 2026-10-06 ([ex-tales-forge #28](https://github.com/whyse-ab/ex-tales-forge/pull/28)). Works without the peer (that section then says "not configured" or "unavailable") | Free (existing app) | — | — (no secret of its own; reads the peer with `COSTS_PEER_TOKEN`) |
| Endpoint `GET /internal/costs` (both apps) | Gives the other app's costs page this app's aggregated AI spend as JSON: totals per bucket and time window only, no rows, prompts or player data. Production fetches playtest's from `COSTS_PEER_URL` (3 s timeout) | Live since 2026-10-06 ([ex-tales-forge #28](https://github.com/whyse-ab/ex-tales-forge/pull/28)). On (`COSTS_PEER_TOKEN` set on both apps); a wrong token gets 401, and it is off (404) whenever the token is unset | Free | — | Fly secret `COSTS_PEER_TOKEN` (same value on both apps, set 2026-10-06); `COSTS_PEER_URL` is config, not a secret |
| GitHub docs token | Lets the admin import from `tales-forge-docs` and check `whyse-ab/tales-forge` team membership | Live (fine-grained, contents read + Members read) | Free | Fredrik | Fly secret `GITHUB_DOCS_TOKEN` |
| GitHub OAuth app *Tales Forge Admin* | "Sign in with GitHub", the only login (every page, from PR #54) | Live since v13 (2026-10-06), registered under `whyse-ab` | Free | Fredrik | Fly secrets `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` |
| GitHub Actions CI and prod deploy | Tests every PR; deploys `main` to `tales-forge` after the tests pass ([environments](environments.md)). `main` is protected: required checks `Test` and `Dialyzer`; the production deploy runs only after both pass | Live (`.github/workflows/ci.yml`, merged in PR #16) | Free (public repo) | Fredrik | `FLY_API_TOKEN` (deploy token for `tales-forge`), an environment secret on `production` and `production-security` |
| Fly app `tales-forge-playtest` | Long-lived playtest (hobby mode: no longer deployed automatically; `.github/workflows/playtest.yml` is started only by hand). Stopping the machines is a later step, after a DB dump and Fredrik's OK | Live at [tales-forge-playtest.fly.dev](https://tales-forge-playtest.fly.dev) since 2026-10-06: arn, shared-cpu-1x 512 MB plus 512 MB swap, 1 machine (`801e9ef6136178`) always on | ~$3.84/month | Fredrik | Fly secrets on `tales-forge-playtest` (`DATABASE_URL`, `SECRET_KEY_BASE`, `ADMIN_EMAILS`, `ADMIN_GITHUB_TEAM`, `XAI_API_KEY`, `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, `GITHUB_DOCS_TOKEN`); Actions secret `FLY_API_TOKEN_PLAYTEST` (set) |
| Postgres `tales-forge-playtest-db` | Playtest database; later also holds one database per PR preview | Live: self-run Fly Postgres (postgres-flex 18.1, same type as prod), arn, single node, shared-cpu-1x 512 MB, 1 GB volume, machine `d8d1116b5d1918`, always on, attached to `tales-forge-playtest` | ~$3.99/month ($3.84 machine plus $0.15 volume) | Fredrik | Fly secret `DATABASE_URL` on `tales-forge-playtest`; superuser password not stored |
| Fly PR preview apps `tales-forge-pr-<n>` | One throwaway app per open PR, with its own database on `tales-forge-playtest-db`, no AI key, destroyed on close | Decided, not built | ~$1.50/month est. | — | Generated per app; Actions secret for a Fly app-creating token (not created) |
| Google Drive folder | Shared docs and persona form until migrated here | Exists ([folder](https://drive.google.com/drive/folders/1tlNoL8WZJPgbFQVT4SipKi9odGnQM_PB)) | Free | Fredrik | — |
| Shared password vault | Logins and secrets not stuck in one head | Not chosen | Depends on tool | — | — |

## Later

| Asset | What it's for | When |
|---|---|---|
| Self-play bots on playtest | Measure bot cost per session apart from real players, using the playtest app's own `XAI_API_KEY` (key exists) | When self-play starts (November) |
| Error and uptime monitoring (e.g. Sentry free tier plus an uptime check) | Know when the game breaks | Before outside players arrive |
| Stripe | Module purchases and prepaid credits | Before the first paying customer |

## To retire

| Asset | Why | When |
|---|---|---|
| Netlify site for tales-forge.ai | Old React app | When the Elixir rewrite replaces it |
| Supabase project | Old app's database and auth | Same time, after any data worth keeping is exported |

## Deploys

Playtest (`playtest.yml`, by hand) and production (`deploy-production.yml`, including calls from `deploy-lanes.yml`) both deploy through `.github/scripts/fly_deploy.sh`: `flyctl deploy --ha=false --wait-timeout 2m`. When Fly never starts a machine of the deploy (the release_command machine, or production's bluegreen green machine, stays in `created`), the script deploys the same pushed image once more (`flyctl deploy --image …`, no rebuild). A build failure, a long migration, a green machine that started but failed its health check, and any other error are not retried. CI runs shellcheck and `.github/scripts/fly_deploy_test.sh` (a fake flyctl, no Fly access) on every PR.

The GitHub environment `production` (repo Settings → Environments) requires `fpahlen` as reviewer, with `can_admins_bypass` false, so every production deploy in it waits for that approval. Bots must never approve production deployments: only Fredrik clicks Approve.

The GitHub environment `production-security` has no reviewer and allows only the branch `main`. `deploy-production.yml` uses it for the security, security-fix and security-rollback lanes on `main`, at all hours (Fredrik, 2026-11-23). Normal and admin deploys keep the `production` environment and its reviewer gate. Both environments hold `FLY_API_TOKEN` as an environment secret; there is no repo-level `FLY_API_TOKEN`.

## GitHub sign-in for the admin

Since [ex-tales-forge PR #54](https://github.com/whyse-ab/ex-tales-forge/pull/54) ([decision 2026-10-07](decisions.md#2026-10-07-github-team-sign-in-is-the-only-login-on-production-and-playtest); in effect once merged and deployed), "Sign in with GitHub" is the only login, and every page (play and admin) needs it. Email magic links are gone. Each app has its own OAuth app, because a classic OAuth app has one callback URL: production uses *Tales Forge Admin* (below), and playtest a second app with callback `https://tales-forge-playtest.fly.dev/admin/auth/github/callback`.

OAuth app settings (GitHub → Settings → Developer settings → OAuth Apps → New OAuth App):

| Setting | Value |
|---|---|
| Application name | Tales Forge Admin |
| Homepage URL | https://tales-forge.fly.dev |
| Authorization callback URL | https://tales-forge.fly.dev/admin/auth/github/callback |
| Device flow | Off |
| Scopes | `read:org user:email` (requested by the app at sign-in; nothing to tick on the OAuth app) |

Who gets in: only active members of the `ADMIN_GITHUB_TEAM` team, `whyse-ab/tales-forge` (pending invites don't count), and every member gets the admin pages too. `ADMIN_EMAILS` no longer counts. Removing someone from the team ends their access within about 5 minutes. Unsetting `ADMIN_GITHUB_TEAM` locks everyone out at once. Nobody's GitHub token is stored. Signed out, only `/admin/login`, the OAuth routes, the Fly health check `/health` and the machine-to-machine `GET /internal/costs` answer. `/internal/costs` needs the bearer token `COSTS_PEER_TOKEN` (401 with a wrong token, 404 while unset) and returns only aggregated spend totals per bucket and time window, no rows, prompts or player data. Everything else redirects to the login page.

Secrets (all required): `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, `ADMIN_GITHUB_TEAM`. The team check also needs `GITHUB_DOCS_TOKEN` to read `whyse-ab` members (fine-grained token: organization permission *Members: read*; classic token: `read:org`).

## Fly secrets checklist

`DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `ADMIN_EMAILS`, `ADMIN_MAIL_FROM`, `MAIL_ADAPTER`, `RESEND_API_KEY` (or `POSTMARK_API_KEY`), `GITHUB_DOCS_TOKEN`, `XAI_API_KEY`; optional `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, `ADMIN_GITHUB_TEAM`, `AI_CAP_SESSION_USD`, `AI_CAP_DAY_USD` (AI spending caps; not set = off, which is how production runs). Never set `PLAYTEST_RUNNER_ENABLED` in production; on playtest it turns on the persona bot runner. Steps are in `docs/DEPLOY-FLY.md` in ex-tales-forge.

Playtest (`tales-forge-playtest`) only needs `DATABASE_URL` and `SECRET_KEY_BASE` to boot. It has `ADMIN_EMAILS`, `ADMIN_GITHUB_TEAM`, its own `XAI_API_KEY` (spending caps `AI_CAP_SESSION_USD` $1.00 and `AI_CAP_DAY_USD` $10.00, set 2026-10-06), and GitHub sign-in (second OAuth app plus `GITHUB_DOCS_TOKEN`) too; `PHX_HOST` is in `fly.playtest.toml`. Per-secret status: [environments](environments.md#secrets-per-environment-names-only) and [fly-secrets](fly-secrets.md#playtest-tales-forge-playtest).
