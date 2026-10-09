# Deploy Tales Forge to Fly.io

App name placeholder: `tales-forge`. Primary region: `arn` (Stockholm).

## Prerequisites

- [Fly CLI](https://fly.io/docs/hands-on/install-flyctl/) installed
- This repo with `Dockerfile`, `fly.toml`, and `rel/overlays`

## 1. Login and launch

```bash
fly auth login
cd ex-tales-forge

# First time only — uses the committed fly.toml, does not deploy yet:
fly launch --no-deploy --copy-config --name tales-forge --region arn
# Or, if the app already exists:
# fly apps create tales-forge --org personal
```

## 2. Postgres

Pick one:

### Option A — Fly Managed Postgres (Basic, ~$38/mo)

Supported managed offering. Simpler ops.

```bash
fly mpg create --name tales-forge-db --region arn
fly mpg attach tales-forge-db -a tales-forge
```

(CLI names vary slightly by flyctl version; `fly postgres` / `fly mpg` — use current docs.)

### Option B — Self-run `fly postgres create` (cheaper, unsupported)

Classic unsupervised Postgres cluster. Cheaper, but **not** covered by Fly Managed support.

```bash
fly postgres create --name tales-forge-db --region arn --vm-size shared-cpu-1x --volume-size 10
fly postgres attach tales-forge-db -a tales-forge
```

Either option sets `DATABASE_URL` on the app.

## 3. Secrets

Generate a secret key base locally:

```bash
mix phx.gen.secret
```

Set every secret (never commit these):

```bash
fly secrets set \
  SECRET_KEY_BASE='<paste mix phx.gen.secret>' \
  PHX_HOST='tales-forge.fly.dev' \
  GITHUB_OAUTH_CLIENT_ID='...' \
  GITHUB_OAUTH_CLIENT_SECRET='...' \
  ADMIN_GITHUB_TEAM='whyse-ab/tales-forge' \
  GITHUB_DOCS_TOKEN='ghp_...' \
  XAI_API_KEY='xai-...' \
  -a tales-forge
```

| Secret | Purpose |
|--------|---------|
| `DATABASE_URL` | Set by `fly postgres attach` / Managed Postgres attach |
| `SECRET_KEY_BASE` | Cookie / session signing |
| `PHX_HOST` | Host for URL generation (update when adding a custom domain) |
| `GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET` | Required. GitHub OAuth app for "Sign in with GitHub", the only login (every page needs it). One OAuth app per host: callback `https://<PHX_HOST>/admin/auth/github/callback` (prod: `https://tales-forge.fly.dev/admin/auth/github/callback`), scopes `read:org user:email`. Without both nobody can sign in |
| `ADMIN_GITHUB_TEAM` | Required, `org/team-slug` (`whyse-ab/tales-forge`). Only active members of this team can sign in, and every member gets the admin pages too; unset = nobody can sign in |
| `GITHUB_DOCS_TOKEN` | Fine-grained or classic PAT with read access to `whyse-ab/tales-forge-docs` and to `whyse-ab` members (the team check for sign-in uses it) |
| `XAI_API_KEY` | Existing Grok LLM key for the game |

Optional: `TALES_FORGE_DOCS_PATH` is for local/dev sync only; production should use `GITHUB_DOCS_TOKEN`.

## 4. Deploy

Normally you don't run `fly deploy` by hand. A push to `main` that passes CI deploys to
**playtest** first (see [Playtest environment](#playtest-environment)). Production is a
separate, manual GitHub Actions workflow, `.github/workflows/deploy-production.yml`
("Deploy to production"), started once the build has been checked on playtest and Fredrik
has OK'd it:

```bash
gh workflow run deploy-production.yml -R whyse-ab/ex-tales-forge -f sha=<full 40-character sha on main>
```

It first checks that the sha is on `main` and that its `Test` and `Dialyzer` checks passed
(and warns if no successful playtest deploy of it is found), then deploys exactly that commit
in the GitHub environment `production` (a required reviewer there makes the job wait for
approval). It uses the Actions secret `FLY_API_TOKEN` (a deploy token scoped to `tales-forge`,
created with `fly tokens create deploy -a tales-forge`). Deploys run one at a time and are
never cancelled mid-way.

Manual deploy, the fallback when Actions is down (same command the workflow runs):

```bash
fly deploy --remote-only --depot=false -a tales-forge --ha=false
```

`release_command` runs `/app/bin/migrate` (Ecto migrations) before the new machines take traffic.

Notes from the first deploy:

- If the Depot builder hangs at "Waiting for depot builder...", use Fly's own builder:
  `fly deploy --remote-only --depot=false -a tales-forge --ha=false`.
- The Docker image uses Elixir 1.18 (jido requires `~> 1.18`).
- `mix compile` must run before `mix assets.deploy` (Phoenix 1.8 colocated hooks/CSS).
- `ECTO_IPV6=true` is set in `fly.toml` because `.flycast` / `.internal` addresses are IPv6-only.
- The HTTP health check hits `GET /health`, the only page that needs no sign-in (everything
  else redirects to `/admin/login`). It sends `X-Forwarded-Proto: https` so `force_ssl`
  doesn't 301 it.

## Playtest environment

A long-lived playtest copy of the game runs as Fly app `tales-forge-playtest`
(<https://tales-forge-playtest.fly.dev>, arn, shared-cpu-1x 512MB, one machine always on),
with its own Fly Postgres cluster `tales-forge-playtest-db` (postgres-flex, single node,
shared-cpu-1x 512MB, 1GB volume, always on). Config: `fly.playtest.toml` (same as `fly.toml`
apart from app name, `PHX_HOST`, memory and `swap_size_mb = 512`: at 512MB without swap the BEAM
is OOM-killed during boot).

Deploys: `.github/workflows/playtest.yml` deploys main to playtest after every green CI run on
main (playtest is the first stop; production follows by hand, see [Deploy](#4-deploy)) and on
demand (Actions → "Deploy to playtest" → Run workflow, or
`gh workflow run playtest.yml -f sha=<sha>`; no sha = the tip of main).
Right before deploying, the workflow fetches `origin/main` and deploys only if the commit is
still the tip of main; otherwise it skips with a notice and the run still succeeds. CI runs can
finish out of order when PRs merge close together, and this keeps playtest from going backwards
(the tip gets its own deploy when its CI passes; if the tip's CI fails, playtest stays where it
was). To deploy an older commit on purpose, run it by hand with
`gh workflow run playtest.yml -f sha=<sha> -f force=true`. Playtest deploys run one at a time
and are never cancelled mid-way.
It uses the Actions secret `FLY_API_TOKEN_PLAYTEST`, a deploy token scoped to the playtest app
(`fly tokens create deploy -a tales-forge-playtest`). It is a separate workflow, so a failed
playtest deploy never fails the CI run.

Manual deploy:

```bash
fly deploy --remote-only --depot=false -c fly.playtest.toml -a tales-forge-playtest --ha=false
```

Secrets (own values, never copied from prod): `DATABASE_URL` (from `fly postgres attach`),
`SECRET_KEY_BASE`, `XAI_API_KEY`, and the sign-in set: its own GitHub OAuth app
(`GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET`, callback
`https://tales-forge-playtest.fly.dev/admin/auth/github/callback`), `ADMIN_GITHUB_TEAM` and
`GITHUB_DOCS_TOKEN` (same team and token as prod). Without `XAI_API_KEY` the game runs with
mock narration.

## 5. Seed decisions / docs

SSH into a machine (or use `fly machine exec`) and run the sync once the app is up:

```bash
fly ssh console -a tales-forge
# Inside the release:
/app/bin/ex_tales_forge eval 'TalesForge.Collab.sync_from_github(System.get_env("GITHUB_DOCS_TOKEN"))'
```

Or from a laptop with the token and a checkout:

```bash
GITHUB_DOCS_TOKEN=… mix tales.sync_docs --github
# against a local DB that you then dump — prefer the eval on Fly above.
```

In the UI: **Admin → Decisions → Sync from repo**.

## 6. Custom domain `admin.tales-forge.ai`

Not in use. `tales-forge.ai` stays on Netlify for now (tales-forge-docs
`docs/decisions.md`, 2026-10-06), no environment gets Fly certificates or DNS
changes, and deploys are checked on `tales-forge.fly.dev` and
`tales-forge-playtest.fly.dev`. Kept for when that decision changes:

```bash
fly certs add admin.tales-forge.ai -a tales-forge
# Add the DNS records Fly prints (A/AAAA or CNAME) at your DNS host.
fly secrets set PHX_HOST='admin.tales-forge.ai' -a tales-forge
# The GitHub OAuth app's callback must then be https://admin.tales-forge.ai/admin/auth/github/callback
fly deploy -a tales-forge
```

Point the public game hostname separately if you use another domain; admin and player share this app.

## Smoke check

1. Open `https://tales-forge.fly.dev/` signed out: it must redirect to `/admin/login`
2. `curl -i https://tales-forge.fly.dev/health` answers `200 ok`
3. "Sign in with GitHub" as a `whyse-ab/tales-forge` team member → back in the app
4. Admin → Decision queue → Sync from repo
