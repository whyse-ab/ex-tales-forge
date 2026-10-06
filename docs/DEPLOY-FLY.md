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
  ADMIN_EMAILS='founder1@example.com,founder2@example.com' \
  MAIL_ADAPTER='resend' \
  RESEND_API_KEY='re_...' \
  ADMIN_MAIL_FROM='admin@tales-forge.ai' \
  GITHUB_DOCS_TOKEN='ghp_...' \
  XAI_API_KEY='xai-...' \
  -a tales-forge
```

| Secret | Purpose |
|--------|---------|
| `DATABASE_URL` | Set by `fly postgres attach` / Managed Postgres attach |
| `SECRET_KEY_BASE` | Cookie / session signing |
| `PHX_HOST` | Host for URL generation (update when adding a custom domain) |
| `ADMIN_EMAILS` | Comma-separated founder emails allowed to magic-link into `/admin` |
| `MAIL_ADAPTER` | `resend` (default) or `postmark` |
| `RESEND_API_KEY` / `POSTMARK_API_KEY` / `MAIL_API_KEY` | Swoosh API key for magic-link email |
| `ADMIN_MAIL_FROM` | From address (must be verified with the mail provider) |
| `GITHUB_DOCS_TOKEN` | Fine-grained or classic PAT with read access to `whyse-ab/tales-forge-docs` (and to `whyse-ab` members if `ADMIN_GITHUB_TEAM` is used) |
| `GITHUB_OAUTH_CLIENT_ID` / `GITHUB_OAUTH_CLIENT_SECRET` | Optional. GitHub OAuth app for "Sign in with GitHub" on `/admin` (callback `https://tales-forge.fly.dev/admin/auth/github/callback`, scopes `read:org user:email`). Without both, the button is hidden |
| `ADMIN_GITHUB_TEAM` | Optional, `org/team-slug` (e.g. `whyse-ab/tales-forge`). Active team members may sign in with GitHub; unset = off |
| `XAI_API_KEY` | Existing Grok LLM key for the game |

Optional: `TALES_FORGE_DOCS_PATH` is for local/dev sync only; production should use `GITHUB_DOCS_TOKEN`.

## 4. Deploy

Normally you don't deploy by hand: GitHub Actions (`.github/workflows/ci.yml`) deploys every push to `main` after the tests pass, using the Actions secret `FLY_API_TOKEN` (a deploy token scoped to `tales-forge`, created with `fly tokens create deploy -a tales-forge`). Deploys run one at a time and are never cancelled mid-way.

Manual deploy (same command CI runs):

```bash
fly deploy --remote-only --depot=false -a tales-forge --ha=false
```

`release_command` runs `/app/bin/migrate` (Ecto migrations) before the new machines take traffic.

Notes from the first deploy:

- If the Depot builder hangs at "Waiting for depot builder...", use Fly's own builder:
  `fly deploy --remote-only --depot=false -a tales-forge --ha=false`.
- The Docker image uses Elixir 1.18 (jido / jido_ai require `~> 1.18`).
- `mix compile` must run before `mix assets.deploy` (Phoenix 1.8 colocated hooks/CSS).
- `ECTO_IPV6=true` is set in `fly.toml` because `.flycast` / `.internal` addresses are IPv6-only.
- The HTTP health check sends `X-Forwarded-Proto: https` so `force_ssl` doesn't 301 it.

## Playtest environment

A long-lived playtest copy of the game runs as Fly app `tales-forge-playtest`
(<https://tales-forge-playtest.fly.dev>, arn, shared-cpu-1x 512MB, one machine always on),
with its own Fly Postgres cluster `tales-forge-playtest-db` (postgres-flex, single node,
shared-cpu-1x 512MB, 1GB volume, always on). Config: `fly.playtest.toml` (same as `fly.toml`
apart from app name, `PHX_HOST`, memory and `swap_size_mb = 512`: at 512MB without swap the BEAM
is OOM-killed during boot).

Deploys: `.github/workflows/playtest.yml` deploys main to playtest after every green CI run on
main (i.e. after the prod deploy) and on demand (Actions → "Deploy to playtest" → Run workflow).
It uses the Actions secret `FLY_API_TOKEN_PLAYTEST`, a deploy token scoped to the playtest app
(`fly tokens create deploy -a tales-forge-playtest`). It is a separate workflow, so a failed
playtest deploy never fails the prod CI run.

Manual deploy:

```bash
fly deploy --remote-only --depot=false -c fly.playtest.toml -a tales-forge-playtest --ha=false
```

Secrets (own values, never copied from prod): `DATABASE_URL` (from `fly postgres attach`),
`SECRET_KEY_BASE`, `ADMIN_EMAILS`, `ADMIN_GITHUB_TEAM`, and `XAI_API_KEY` once added. Without
`XAI_API_KEY` the game runs with mock narration. No mail key (magic links aren't delivered), no
GitHub OAuth app (its callback is fixed to `tales-forge.fly.dev`) and no `GITHUB_DOCS_TOKEN`
(docs sync in the admin is unavailable).

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

```bash
fly certs add admin.tales-forge.ai -a tales-forge
# Add the DNS records Fly prints (A/AAAA or CNAME) at your DNS host.
fly secrets set PHX_HOST='admin.tales-forge.ai' -a tales-forge
fly deploy -a tales-forge
```

Point the public game hostname separately if you use another domain; admin and player share this app.

## Smoke check

1. Open `https://admin.tales-forge.ai/admin/login` (or `https://tales-forge.fly.dev/admin/login`)
2. Request a magic link for an allowlisted email
3. Confirm the email arrives (Resend/Postmark dashboard)
4. Open the link → Decision queue → Sync from repo
