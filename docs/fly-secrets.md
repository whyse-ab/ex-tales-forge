---
title: "Adding API keys and secrets to Fly"
updated: 2026-10-09
---

# Adding API keys and secrets to Fly

API keys, passwords and tokens go into **Fly secrets**, never into the code or `fly.toml`. Fly stores them encrypted and gives them to the app as environment variables. Setting or changing a secret restarts the app, which takes about 10 seconds.

Apps: `tales-forge` (production) and `tales-forge-playtest` (playtest), org `personal`, account fredrik@whyse.se. Each app has its own secrets; never copy a value from one to the other. The exceptions are `GITHUB_DOCS_TOKEN` and `COSTS_PEER_TOKEN`, which must be the same on both apps. The tables below cover production first, then [playtest](#playtest-tales-forge-playtest).

**Sign-in secrets check (2026-10-07, for ex-tales-forge PR #54, GitHub team sign-in only):** `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, `GITHUB_DOCS_TOKEN` and `ADMIN_GITHUB_TEAM` are set on both apps. Compared by digest, not by value: `GITHUB_DOCS_TOKEN` and `ADMIN_GITHUB_TEAM` match, and the OAuth client ID and secret differ, because each app has its own OAuth app. Nothing was added or staged.

## Option 1: the Fly dashboard (easiest)

1. Sign in at [fly.io](https://fly.io/dashboard) as fredrik@whyse.se.
2. Open the app **tales-forge** and go to **Secrets** ([direct link](https://fly.io/apps/tales-forge/secrets)).
3. Add a secret with the name from the table below and paste the value.
4. Deploy the secret. The app restarts with the new value.

## Option 2: the command line

On your own computer, with [flyctl installed](https://fly.io/docs/flyctl/install/):

```sh
fly auth login                                   # once, opens the browser
fly secrets set XAI_API_KEY=xai-... -a tales-forge
fly secrets list -a tales-forge                  # shows names only, never values
fly secrets unset SOME_NAME -a tales-forge       # remove one
```

Tip: put a space before the command so it doesn't end up in your shell history (works in most shells), or use `fly secrets import -a tales-forge` and paste `NAME=value` lines, then press Ctrl-D.

## Option 3: ask a bot

Ask Case or Bobby to add a key. You get a masked input box in the chat, so the value never appears in the conversation, and the bot sets it on Fly for you.

## Which secrets the app uses (production, `tales-forge`)

| Name | What it's for | Set? (2026-10-06) |
|---|---|---|
| `DATABASE_URL` | Connection to the Postgres app `tales-forge-db` | Yes (set by `fly postgres attach`) |
| `SECRET_KEY_BASE` | Signs sessions and cookies. Rotating it logs everyone out | Yes |
| `PHX_HOST` | Public host name (`tales-forge.fly.dev`) | Yes |
| `ADMIN_EMAILS` | Was the magic-link allowlist. **Unused since ex-tales-forge PR #54** (GitHub team sign-in only); still set, can be unset once the PR is deployed | Yes, fredrik@whyse.se only |
| `GITHUB_DOCS_TOKEN` | Fine-grained GitHub token (owner `whyse-ab`): read-only contents so the admin can import this docs repo, plus organization *Members: read* for the admin team check | Yes |
| `XAI_API_KEY` | AI game master (xAI). Without it the GM gives mock narration | Yes (since 2026-10-06) |
| `GITHUB_OAUTH_CLIENT_ID` | "Sign in with GitHub", the only login (every page, PR #54): Client ID of the GitHub OAuth app *Tales Forge Admin* (callback `https://tales-forge.fly.dev/admin/auth/github/callback`, see [infrastructure.md](infrastructure.md#github-sign-in-for-the-admin)). Without it and the secret nobody can sign in | Yes (live since v13, 2026-10-06) |
| `GITHUB_OAUTH_CLIENT_SECRET` | Client secret of the same OAuth app | Yes (live since v13, 2026-10-06) |
| `ADMIN_GITHUB_TEAM` | Required since PR #54. The GitHub team as `org/team-slug`, `whyse-ab/tales-forge`: only its active members can sign in (to everything, admin included). Unset = nobody can sign in. Needs `GITHUB_DOCS_TOKEN` to be able to read `whyse-ab` members | Yes: `whyse-ab/tales-forge` (since v15, 2026-10-06) |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | Optional other AI providers | No |
| `AI_CAP_SESSION_USD`, `AI_CAP_DAY_USD` | Optional AI spending caps in USD, per game session and per day (since midnight Stockholm time). Not set = that cap is off. The session cap counts only the game's calls, not the persona bot or the judge; the day cap counts everything (ex-tales-forge PR #20, #24). Not secret, but set the same way | No, not set = off |
| `AI_CAP_PERSONA_RUN_USD` | Optional cap in USD on the persona bot's own AI calls per playtest run; hitting it stops the run (`persona_cap`). **Defaults to $0.50 when not set** (ex-tales-forge PR #24). Not secret, but set the same way | No (the runner never runs in production) |
| `PLAYTEST_RUNNER_ENABLED` | Turns on the persona bot runner (ex-tales-forge PR #23) when set to `true`. Not secret, but set the same way | **Never** set in production |
| `COSTS_PEER_TOKEN` | Shared bearer token for the admin costs page (ex-tales-forge PR #28). It turns on this app's `GET /internal/costs` (off with a 404 while unset) and lets this app read the other app's numbers. **Same value on both apps**: generate it once (e.g. `openssl rand -hex 32`) and set it on `tales-forge` and `tales-forge-playtest` | Yes, since 2026-10-06 (same value as playtest) |
| `COSTS_PEER_URL` | Base URL of the other app for the costs page: `https://tales-forge-playtest.fly.dev` on production. Config, not a secret, but set the same way. Without it (or without the token) the page says "not configured". **No longer read since ex-tales-forge [#90](https://github.com/whyse-ab/ex-tales-forge/pull/90) was deployed (2026-10-09)** (playtest's URL then comes from config); can be unset | Yes, since 2026-10-06: `https://tales-forge-playtest.fly.dev` |
| `GITHUB_FEED_TOKEN` | Live PR feed on the founders' page (`/team`, section "Live: what we're shipping", ex-tales-forge PR [#102](https://github.com/whyse-ab/ex-tales-forge/pull/102)). Fine-grained GitHub token, resource owner `whyse-ab`, repository access **only `whyse-ab/ex-tales-forge`**, read-only: *Pull requests: read*, *Contents: read*, *Actions: read* (*Metadata: read* is added automatically). The server polls GitHub with it every 60 s; browsers never call GitHub. Unset = the section says "Live feed unavailable" and the rest of the page works. Can be the same value on both apps (read-only, one repo). `GITHUB_DOCS_TOKEN` can't be reused: it has no pull request or Actions access. "On playtest / on prod" also uses the existing `COSTS_PEER_TOKEN` (the other app's `GET /internal/version`). Setting it on production needs Fredrik's OK | **Yes, set 2026-10-09 (Fredrik)**, the same value as playtest (same Fly digest, checked 2026-10-09 ~17:40 by name and digest only). Read only once a release with #102 (`eec7ddf`) is deployed to production; until then it sits unused |
| `GENTRY_QA_TOKEN` | Gentry's QA sign-in on `/team` (ex-tales-forge PR [#175](https://github.com/whyse-ab/ex-tales-forge/pull/175)). Gentry gives this token at `/team/qa-login` and gets a **read-only** browser session as "Gentry (QA)" for `/team` and `/team/presentation`. The server refuses every write, the session never clears pings, and it does not show in "Online now". Unset = `/team/qa-login` answers 404. **Same value on both apps.** Gentry's copy is on the box at `/home/box/.config/tales-forge/gentry-qa-token` (mode 600). To rotate: write a new value to that file and set it on both apps (see below); old QA sessions stop at the next request | **Staged 2026-10-12** on both apps (same value), applies with the next deploy |
| `QA_ALLOW_WRITES` | `true` lets the QA session write, **on playtest only**, for later write-path tests. Production ignores it. Config, not a secret. Turning it on needs Fredrik's OK | **No, off** (unset). Never set on production |
| `TYPESAFE_API_KEY` | TypeSafe Jev API key for persona-affect scoring. **Do not set on production yet** (playtest only) | No, not yet |
| `TYPESAFE_INTENT_API_KEY` | TypeSafe Jev key for the Jev intent call (intent + safety label in one call, [design](design-jev-intent.md)). **Set 2026-10-08 with Fredrik's OK**: the key Fredrik created as tales-forge-intent (production only; playtest got its own key the same day, so intent usage is split per app at TypeSafe). Read by ex-tales-forge PR [#84](https://github.com/whyse-ab/ex-tales-forge/pull/84) (merged 2026-10-08) as the named Jev endpoint `:intent`. Used for every new default-variant session since `INTENT_JEV=on` (2026-10-09) | Yes, since 2026-10-08 (in use since 2026-10-09, `INTENT_JEV=on`) |
| `PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE` | Minimum confidence (0..1, default `0.90`) that the intent call's safety read must give `benign` for the GM to get the player's own words; below it the GM gets the intent summary ([decision 2026-10-08](decisions.md#2026-10-08-clarification-the-safety-read-is-part-of-the-intent-call-not-a-separate-jev-call); the rule carries over from ex-tales-forge PR #76, **closed 2026-10-08, superseded by the [Jev intent design](design-jev-intent.md)**). Config, not a secret; set the same way | No, not set = 0.90 |
| `INTENT_JEV` | Jev intent mode for new default-variant sessions (ex-tales-forge PR [#84](https://github.com/whyse-ab/ex-tales-forge/pull/84), merged 2026-10-08, prod v81): `off` (default, today's intent path), `shadow` (today's path plays; the Jev read runs alongside and is only logged in `ai_calls`, purpose `turn.intent_shadow`) or `on` (the Jev read drives the turn; the heuristic takes over on error or timeout). Pinned per session at creation (`world_state["intent_jev"]`); the baseline variant is always off. Needs `TYPESAFE_INTENT_API_KEY`. **Config, not a secret.** **`on` on both apps since 2026-10-09** (Fredrik's OK; playtest was on `shadow` 2026-10-08 to 2026-10-09). Changing it needs Fredrik's OK | **Yes, `on`: set 2026-10-09 with Fredrik's OK** (release v85, after the [persona comparison](analysis-intent-compare-2026-10-09.md); [decision](decisions.md#2026-10-09-jev-intent-on-for-playtest-and-production)). New default-variant sessions use the Jev read; sessions created before the switch keep their pinned mode |
| `INTENT_ACT_MIN_CONFIDENCE` | With `INTENT_JEV=on`: calibrated confidence at or above which the turn acts on the top reading (default `0.70`). Config, not a secret | No, not set = 0.70 |
| `INTENT_ASK_BELOW_CONFIDENCE` | With `INTENT_JEV=on`: calibrated confidence below which the turn may ask, and only when the top two readings would play out differently (default `0.45`). Config, not a secret | No, not set = 0.45 |
| `INTENT_JEV_TIMEOUT_MS` | With `INTENT_JEV=on`: hard deadline in ms of the Jev call on the player's clock before the heuristic takes over (default `1500`). Config, not a secret | No, not set = 1500 |
| `INTENT_CALL_EVERY_TURN` | `on` sends every default-variant turn through the intent call, even when the heuristic is confident, so every turn has a safety read and can quote the player's own words. Costs one intent call per turn (about $0.0023 and 2 s on the player's clock). Default off: heuristic turns get a typed summary (ex-tales-forge PR #76, **closed 2026-10-08, superseded by the [Jev intent design](design-jev-intent.md)**; under the Jev plan every default-variant turn makes one Jev call, so this flag is no longer needed). Config, not a secret. Turning it on needs Fredrik's OK | No, off (unset) |
| `NPC_REACTIONS` | `on` turns on the Jev NPC reaction before each GM call (ex-tales-forge PR #40; needs `TYPESAFE_API_KEY`). Default off. Not secret, but set the same way | **No, off** (unset) |
| `WORLD_AGENTS` | `on` turns on the world-agents prototype: persons and locations hold facts for the GM (ex-tales-forge PR #40; also turns on NPC reactions). Default off. Not secret | **No, off** (unset) |
| `INN_WORLD` | `on` gives new Tin Valley sessions the places and people around the inn ([design](design-tin-valley-world.md), ex-tales-forge PR #72). Read when a session is created. Default off. Not secret | **No, off** (unset) |
| `WORLD_ANTAGONIST` | `on` adds the Tinjacks antagonist (a front on world time, with Rusk, Cobb and Pip) to new Tin Valley sessions; needs `INN_WORLD` ([design](design-tin-valley-world.md), ex-tales-forge PR #73). Default off. Not secret | **No, off** (unset) |
| `MAIL_ADAPTER` | Email provider, e.g. `resend`. Nothing sends mail since magic links were removed (PR #54) | No, see [Resend setup](resend-setup.md) |
| `RESEND_API_KEY` | Resend sending key | No |
| `ADMIN_MAIL_FROM` | Sender address for login emails (default `admin@tales-forge.ai`) | No |
| `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY` | The VAPID key pair for web push of the installed team app (`Workflow.Push`, ex-tales-forge PR [#277](https://github.com/whyse-ab/ex-tales-forge/pull/277)). Url-safe base64, P-256. Unset = push is off. A new pair stops all stored subscriptions, so each founder must allow notifications again | **Staged 2026-10-14** (own pair) |

Mailgun and Postmark (`MAILGUN_API_KEY`, `MAILGUN_DOMAIN`, `POSTMARK_API_KEY`) are also supported by the code but not used.

Fixed costs on the costs page (Fly machines, GitHub, the domain, other hosting and so on), the USD to SEK rate and the playtest warning threshold are not secrets. They live in one config block in ex-tales-forge, `config :ex_tales_forge, TalesForge.Costs` in `config/config.exs`. Each item is either `{:usd_per_month, n}` or `{:sek_per_year, n}` (converted at the configured rate, shown as yearly and as monthly share ÷ 12); `:unknown` stays out of the totals. Domain tales-forge.ai is SEK 2,318.75/year and other hosting-related costs are SEK 400/year (both from Fredrik 2026-10-06). Edit the figures there.

Jev persona-affect scoring (playtest) uses `TYPESAFE_API_KEY` and Hex `jev` pinned to model `jev-1.13.0`. Usage is also mirrored into `ai_calls` as purpose `scorer`. Jev is billed at TypeSafe (~$0.042/1M input); see [jev-scoring.md](jev-scoring.md).

## Playtest (`tales-forge-playtest`)

Same names as production, with **separate values** (never copied from prod), except `GITHUB_DOCS_TOKEN`, which is the same read-only whyse-ab token, and `COSTS_PEER_TOKEN`, which must match production's. [Dashboard](https://fly.io/apps/tales-forge-playtest/secrets); on the command line use `-a tales-forge-playtest`.

| Name | Set? (2026-10-06) |
|---|---|
| `DATABASE_URL` | Yes, set by `fly postgres attach tales-forge-playtest-db` (database `tales_forge_playtest` on the playtest cluster) |
| `SECRET_KEY_BASE` | Yes, newly generated for playtest |
| `ADMIN_EMAILS` | Yes, fredrik@whyse.se only. Unused since PR #54 (GitHub team sign-in only); can be unset once deployed |
| `ADMIN_GITHUB_TEAM` | Yes, `whyse-ab/tales-forge`. Since PR #54 the only way in: active team members (the founders) sign in with GitHub; pending invites don't count |
| `XAI_API_KEY` | Yes, live: a separate playtest key (added by Case), so bot and tester cost is counted apart from production |
| `PHX_HOST` | Not a secret: `tales-forge-playtest.fly.dev` is in `fly.playtest.toml` |
| `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` | Yes, from a second OAuth app for playtest (callback `https://tales-forge-playtest.fly.dev/admin/auth/github/callback`) |
| `GITHUB_DOCS_TOKEN` | Yes, the same fine-grained whyse-ab token as production (contents read, Members read). Used for the team check and "Sync from repo" |
| `MAIL_ADAPTER`, `RESEND_API_KEY`, `ADMIN_MAIL_FROM` | No. Not needed: magic-link sign-in was removed (PR #54) |
| `AI_CAP_SESSION_USD`, `AI_CAP_DAY_USD` | Yes, since 2026-10-06: $1.00 per session, $10.00 per day. **2026-10-07, about 19:40: day cap raised to $25.00** (Fredrik via Case) so it can't bind during the overnight baseline series `baseline-2026-10-07` (about $8.50 for 65 runs); kept as a runaway backstop, and Fredrik lowers it again himself. The session cap stays at $1.00. Changing them needs Fredrik's OK |
| `AI_CAP_PERSONA_RUN_USD` | Not set, so the $0.50 per run default applies (from ex-tales-forge PR #24). Set it like the other caps (`fly secrets set AI_CAP_PERSONA_RUN_USD=... -a tales-forge-playtest`) only to change that; changing it needs Fredrik's OK |
| `PLAYTEST_RUNNER_ENABLED` | Yes, `true`: staged 2026-10-06 with the deploy of ex-tales-forge PR #23 |
| `COSTS_PEER_TOKEN` | Set 2026-10-06. The **same value** as on production; it turns on playtest's `GET /internal/costs`, which production's costs page reads |
| `COSTS_PEER_URL` | Set 2026-10-06: `https://tales-forge.fly.dev`, so playtest's costs page shows production too. Config, not a secret. **No longer read since ex-tales-forge [#90](https://github.com/whyse-ab/ex-tales-forge/pull/90) was deployed (2026-10-09)** (playtest's page then shows only playtest runs); can be unset |
| `GITHUB_FEED_TOKEN` | **Yes, set 2026-10-09 (Fredrik)**, the same value as production (same Fly digest, checked 2026-10-09 ~17:40 by name and digest only, never the value). The live PR feed on `/team` (ex-tales-forge PR [#102](https://github.com/whyse-ab/ex-tales-forge/pull/102), merged 2026-10-09 as `eec7ddf`); a fine-grained read-only token (only `whyse-ab/ex-tales-forge`: Pull requests, Contents and Actions read). Unset = "Live feed unavailable" |
| `TYPESAFE_API_KEY` | TypeSafe Jev (persona-affect scorer, and the NPC reaction when `NPC_REACTIONS=on`). Console key name tales-forge-scorer. **Yes, set 2026-10-07** on playtest only | Yes, since 2026-10-07 |
| `NPC_REACTIONS` | Yes, `on` since 2026-10-07 (Fredrik's OK, release v25): Brenna and other present NPCs get a Jev reaction before each GM call (`ai_calls` purpose `npc_reaction`). Unset it to turn it off |
| `WORLD_AGENTS` | Not set (off). The world-agents prototype stays off on playtest for now |
| `INN_WORLD` | Yes, `on`, set in `fly.playtest.toml` `[env]` by ex-tales-forge PR #72 (not a Fly secret). Live since 2026-10-08 (merge `9080cb1`, playtest release v58); new sessions only |
| `WORLD_ANTAGONIST` | Yes, `on`, set in `fly.playtest.toml` `[env]` by ex-tales-forge PR #73 (not a Fly secret). Live since 2026-10-08 (merge `9e7d447`, playtest release v59); new sessions only |
| `TYPESAFE_INTENT_API_KEY` | TypeSafe Jev key for the Jev intent call ([design](design-jev-intent.md), 2026-10-08; separate from the scorer). **Playtest's own key**, created by Fredrik 2026-10-08 and set the same day (replacing the production key it had shared), so TypeSafe reports playtest intent usage apart from production. Never copy production's value here. Read by ex-tales-forge PR [#84](https://github.com/whyse-ab/ex-tales-forge/pull/84) (merged 2026-10-08) when `INTENT_JEV` is `shadow` or `on`. | Yes, Deployed 2026-10-08 |
| `PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE` | Not set, so the 0.90 default applies. With `INTENT_JEV=on` (ex-tales-forge PR [#84](https://github.com/whyse-ab/ex-tales-forge/pull/84), merged 2026-10-08) the GM gets the player's own words only for a `benign` safety read at or above this; otherwise a typed summary. Config, not a secret. Changing it needs Fredrik's OK |
| `INTENT_JEV` | **Yes, `on` since 2026-10-09 with Fredrik's OK** (release v76; [decision](decisions.md#2026-10-09-jev-intent-on-for-playtest-and-production)). New default-variant sessions use the Jev read for intent; the heuristic takes over on error or timeout. Before that it was `shadow` from 2026-10-08 (release v72, ex-tales-forge PR [#84](https://github.com/whyse-ab/ex-tales-forge/pull/84)), when the Jev read was only logged. Sessions created before the switch keep their pinned mode; baseline sessions stay off. Config, not a secret. Changing it needs Fredrik's OK |
| `INTENT_ACT_MIN_CONFIDENCE`, `INTENT_ASK_BELOW_CONFIDENCE`, `INTENT_JEV_TIMEOUT_MS` | Not set, so the defaults apply (0.70, 0.45, 1500 ms). Config, not secrets. Changing them needs Fredrik's OK |
| `INTENT_CALL_EVERY_TURN` | Not set (off). Turning it on (every turn through the intent call, about $0.0023 more per turn) needs Fredrik's OK |
| `GENTRY_QA_TOKEN` | **Staged 2026-10-12**, the **same value** as production. Turns on `/team/qa-login` here too (ex-tales-forge PR [#175](https://github.com/whyse-ab/ex-tales-forge/pull/175)) |
| `QA_ALLOW_WRITES` | Not set (off). `true` lets the Gentry (QA) session write on playtest only. Turning it on needs Fredrik's OK |
| `WEB_PUSH_VAPID_PUBLIC_KEY`, `WEB_PUSH_VAPID_PRIVATE_KEY` | **Staged 2026-10-14**, its own key pair (not the production pair). Web push of the installed team app (`Workflow.Push`) |

GitHub Actions secret for deploying playtest: `FLY_API_TOKEN_PLAYTEST`, a deploy token for `tales-forge-playtest` only (Fly dashboard → tales-forge-playtest → Tokens, or `fly tokens create deploy -a tales-forge-playtest`). Set.

## Gentry's QA sign-in (`GENTRY_QA_TOKEN`)

Gentry signs in to `/team` with its own token, not with a founder's GitHub session.

**Set or rotate the token** (from a box where `flyctl` is signed in; the value never shows on the screen):

```bash
umask 077
openssl rand -base64 32 | tr -d '\n/+=' > /home/box/.config/tales-forge/gentry-qa-token
chmod 600 /home/box/.config/tales-forge/gentry-qa-token
for app in tales-forge tales-forge-playtest; do
  printf 'GENTRY_QA_TOKEN=%s\n' "$(cat /home/box/.config/tales-forge/gentry-qa-token)" \
    | fly secrets import -a "$app"
done
```

Add `--stage` to `fly secrets import` to apply the value with the next deploy and not restart the app now.

**How Gentry signs in** (in Gentry's box browser):

1. Open `https://tales-forge.fly.dev/team/qa-login` (playtest: `https://tales-forge-playtest.fly.dev/team/qa-login`).
2. Read the token from `/home/box/.config/tales-forge/gentry-qa-token`. Type it in the **Token** field. Do not put the token in a URL, a log or a message.
3. Click **Sign in**. The browser opens `/team` with the line "Signed in as Gentry (QA)."
4. The session stays in the browser cookie. Open `/team` and `/team/presentation` as usual.
5. To sign out, open `/admin/logout`, or clear the cookies.

The session can view everything on the team pages. Each write (add, vote, move, comment, Approve, answers, images, tags, chat) is refused on the server with the message "This QA session is read-only." Other pages (admin, game) send the QA session to the login page.

## GitHub Actions secrets for the security lane

The security lane ([environments.md](environments.md#security-lane-advisory-fixes-ship-without-a-founder-ok), [decision 2026-10-11](decisions.md#2026-10-11-security-bump-lane), ex-tales-forge [#171](https://github.com/whyse-ab/ex-tales-forge/pull/171)) uses these GitHub Actions secrets in ex-tales-forge (repo Settings → Secrets and variables → Actions). They are not Fly secrets. None is set yet.

| Name | What it is | Without it |
|---|---|---|
| `SECURITY_BOT_APP_ID`, `SECURITY_BOT_APP_PRIVATE_KEY` | The bot that pushes the audit's branch, opens the `security:` PR and merges it. A GitHub App installed on `whyse-ab/ex-tales-forge` only, with *Contents: write*, *Pull requests: write* and *Issues: write* (for the label). Add the App as a bypass actor in the `main` ruleset, so it can merge without a review. A PR or merge made with the default `GITHUB_TOKEN` does not start CI, so the bot must be an App (or a PAT) | Set `SECURITY_BOT_TOKEN` instead. With neither, the audit only reports, and a qualifying PR waits for a founder's Approve |
| `SECURITY_BOT_TOKEN` | Optional fallback for the App: a fine-grained PAT, resource owner `whyse-ab`, repository access only `whyse-ab/ex-tales-forge`, *Contents: write*, *Pull requests: write*, *Issues: write* | See above |
| `SECURITY_LANE_WEBHOOK_URL` | Optional: Bobby's webhook. After a security-lane production deploy, it gets a JSON note (`security_lane.deployed`: sha, PR, advisory ids, run link) | No note; the run summary says so |
| `SECURITY_LANE_WEBHOOK_KEY` | Optional: the key sent as `Authorization: Bearer <key>` and used for `X-Security-Lane-Signature: sha256=<HMAC-SHA256 of "<timestamp>.<body>">`, the same scheme as the board webhooks | The note goes out unsigned |


## GitHub Actions secrets for the weekly prod backup

Hobby mode step 2 (`.github/workflows/prod-backup.yml`). The repo is public, so the dump is encrypted with [age](https://age-encryption.org) before it is stored as an Actions artifact (kept 90 days). A plaintext dump is never uploaded. None of these is set by the PR; Fredrik adds them in repo Settings → Secrets and variables → Actions.

| Name | What it is | Without it |
|---|---|---|
| `FLY_API_TOKEN_DB` (secret) | A Fly token that can proxy the Postgres app `tales-forge-db` (for example `fly tokens create deploy -a tales-forge-db`). Do not reuse `FLY_API_TOKEN`, which is scoped to the web app `tales-forge` only | The backup job fails; no dump is taken |
| `PROD_PGPASSWORD` (secret) | Password for `PROD_PGUSER` on the prod database | The backup job fails; no dump is taken |
| `BACKUP_AGE_RECIPIENT` (variable or secret) | An age X25519 public key (`age1…`). A repository variable is enough. Fredrik keeps the private key offline and decrypts with `age -d -i key.txt dump.age > dump` | The backup job fails rather than upload a plaintext dump |
| `PROD_PGUSER` (optional variable or secret) | Database role. Default `postgres` | The default is used |
| `PROD_PGDATABASE` (optional variable or secret) | Database name. Default `tales_forge` | The default is used; override if `fly postgres attach` created a different name |

## Good habits

- Use a separate key per environment (local `.env` vs Fly) and per provider account, so one can be revoked without breaking the other.
- Give keys the smallest permissions that work (e.g. sending-only for Resend, read-only contents for GitHub).
- When someone leaves or a key may have leaked: create a new key at the provider, `fly secrets set` it, then revoke the old one.
- Record new secret names (never values) in this table and in [infrastructure.md](infrastructure.md).
