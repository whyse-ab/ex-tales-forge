# Jev intent: DOE screen of read setups (plan)

2026-11-23. Owner: Fredrik ("Yes lets plan and run a DOE", 2026-11-23 05:17 Stockholm). Author: Case (review lane). Docs only: no code, config or Fly changes.

## 1. Goal

Find out which settings of the Jev (TypeSafe System One, `jev-1.13.0`) player-intent read change accuracy and material errors, and which don't. Do it with as few runs as possible. Then tune thresholds and calibration offline on the winning setup, and confirm once on the holdout.

## 2. Responses

Scored by `mix intent.eval` on the **tune split only** (327 items).

| | Response | Source |
|---|---|---|
| Primary | Action accuracy | report, Jev reader |
| Primary | Material-error rate (wrong action of another consequence class, played without a question) | report, decision-band table |
| Secondary | Target accuracy, skill accuracy, deferred (`later`) F1 | report |
| Secondary | Safety recall (nefarious), safety false positives | report |
| Secondary | ECE (calibrated and raw) | report |
| Secondary | Timeout / error rate | `jev error` log lines + error count |
| Secondary | p50 / p95 latency | `ai_calls` rows of the run (local dev DB) |

**Two item sets.** 80 of the 327 tune items are unreviewed drafts (`reviewed: false`). Every run is reported on **all 327** and on the **247 reviewed** items (via `--dump`, joined on `id`). Decisions use the 247 set. The 327 set shows whether the drafts point the same way.

**Baseline** (2026-10-08, 247 reviewed items, 4 s timeout): action 95.1 %, material error 1.2 %, ECE 0.041, clarify 0 %.

## 3. Factors and levels

"−" means today's default on prod. "+" means the alternative.

| | Factor | − | + | How to vary it in the eval today |
|---|---|---|---|---|
| A | Catalogue | v1 | v2 | **Runnable now.** `JEV_CATALOGUE_V2=on` (read via `JevIntent.questions/1` → `catalogue/0`) |
| B | Self-check question | off | on | **Runnable now.** `JEV_SELF_CHECK=on` (`JevSelfCheck.ask/1` default) |
| C | Skill split question | off | on | **Needs Bobby: small switch PR.** The eval calls `JevIntent.questions/1`, so `SKILL_SPLIT` has no effect there. Only the live path (`intent_jev.ex:198`) uses `questions/3`. |
| D | Context window | 800 chars narration / 600 chars player text | 1600 / 1200 | **Needs Bobby: small switch PR.** Hard-coded: `jev_intent.ex` `last_narration/1` (800) and `@action_chars 600`. |
| E | Last 3 player actions in state | not sent | sent | **Needs Bobby: small switch PR.** Not in `JevIntent.state/2` today. The fixture context would also need the previous actions. |
| F | Question / label wording | current | one alternative wording set | **Needs Bobby: small switch PR.** Wording is compiled module attributes (`@action_labels` etc.) with no switch. |

Verified 2026-11-23 on `a5a0d2a6`: the question keys of the eval request change with A (`then, then2, manner` added) and B (`self_check` added), and do **not** change with `SKILL_SPLIT`.

**Catalogue v2 caveat.** Eval gold is v1. A v2 reading is scored through `JevIntent.v1_actions/1` (`metrics.ex`), so `none_fits`, `then`, manner and the extra skills are not graded. A + can only show whether v2 hurts or helps the v1 decisions. It cannot show v2's own gains.

## 4. Full design (once C–F have switches): 2^(6−2), resolution IV, 16 runs

Generators E = ABC, F = BCD. Defining relation I = ABCE = BCDF = ADEF. Main effects are clear of two-factor interactions. Two-factor interactions are aliased in chains: AB=CE, AC=BE, AD=EF, AE=BC=DF, AF=DE, BD=CF, BF=CD.

| Run | A cat | B self-check | C split | D context | E last 3 | F wording |
|---|---|---|---|---|---|---|
| S01 | − | − | − | − | − | − |
| S02 | + | − | − | − | + | − |
| S03 | − | + | − | − | + | + |
| S04 | + | + | − | − | − | + |
| S05 | − | − | + | − | + | + |
| S06 | + | − | + | − | − | + |
| S07 | − | + | + | − | − | − |
| S08 | + | + | + | − | + | − |
| S09 | − | − | − | + | − | + |
| S10 | + | − | − | + | + | + |
| S11 | − | + | − | + | + | − |
| S12 | + | + | − | + | − | − |
| S13 | − | − | + | + | + | − |
| S14 | + | − | + | + | − | − |
| S15 | − | + | + | + | − | + |
| S16 | + | + | + | + | + | + |

Plus **2 replicates of S01** (baseline) to measure run-to-run noise. Total: 18 × 327 ≈ 5,900 calls ≈ $0.71 at ≈ $0.00012 per item.

## 5. Reduced design, runnable now: 2^2 on A, B

| Run | A cat | B self-check | Env |
|---|---|---|---|
| R1 | − | − | (none) |
| R2 | + | − | `JEV_CATALOGUE_V2=on` |
| R3 | − | + | `JEV_SELF_CHECK=on` |
| R4 | + | + | both |
| R1b, R1c | − | − | replicates of R1 |

6 × 327 = 1,962 calls ≈ $0.24.

C is left out because `SKILL_SPLIT` does not reach the eval request (see §3). With C's switch, this becomes the full 2^3 = 8 runs plus replicates (≈ $0.31).

Command per run, from a scratch copy of the repo with a local dev DB. Use playtest key `TYPESAFE_INTENT_PLAYTEST_API_KEY` so runs bill to playtest, not prod:

```
<env flags> mix intent.eval --split tune --readers jev,heuristic \
  --timeout-ms 1500 --concurrency 4 \
  --cache results/cache/<run> --dump results/<run>.jsonl --out results/<run>.md
```

- `--timeout-ms 1500` matches live, not the 4 s eval default.
- Concurrency starts at 4. Back off to 2 on 429s or a timeout rate above 2 %.
- **Each run, and each replicate, gets its own cache dir.** Otherwise a replicate is read from the cache and shows zero noise. Offline sweeps (§6) reuse a run's own cache and cost nothing.
- Never `--split holdout` / `--i-mean-it` in this phase.

## 6. Analysis

1. **Noise.** Take the spread of R1/R1b/R1c on each primary response, and the per-item flip rate between replicates (how often the same item changes right/wrong). An effect smaller than the replicate spread is ignored.
2. **Main effects** (and the AB interaction in the 2^2). Effect = mean(+) − mean(−) per response, on 247 reviewed and on 327.
3. **Paired test vs baseline.** McNemar on per-item right/wrong for each run vs R1 (from `--dump`). The discordant-pair count is reported alongside p. About 12 errors per run at 95 % means only large effects are detectable. Small differences are "no evidence", not "no effect".
4. **Guardrails.** A setup that raises the material-error rate, lowers safety recall, or raises timeouts at 1.5 s loses, whatever its accuracy.
5. **Winner, then offline tuning** (no new Jev calls, via `--cache`): sweep `--ask-below` / `--ask-below-raw` and the act threshold, then refit the calibration with `--fit-calibration` and a new `--calibration-version`, on the 247 reviewed items. Report 5-fold CV ECE. The refit is a proposal only; shipping it is a code PR by Bobby with Fredrik's merge.
6. **Holdout.** The 103 holdout items are run **once**, on the final setup and thresholds, only on Fredrik's explicit go. They are not used for any choice.

## 7. Limits

- Cost cap for the screen: $2 total.
- No prod or Fly changes. Runs use a local dev DB, so `ai_calls` rows land there, not on prod.
- The TypeSafe key must be the playtest intent key. Its value is never printed or committed.
- Results docs carry aggregate numbers only, no player text.

## 8. Status (2026-11-23)

- Build: OK in a scratch copy (Elixir 1.18.4 / OTP 27). A keyless heuristic smoke run against the local dev DB works.
- **Blocked:** no TypeSafe key on the eval machine (none of `TYPESAFE_INTENT_PLAYTEST_API_KEY`, `TYPESAFE_INTENT_API_KEY`, `TYPESAFE_API_KEY` is set or stored). The reduced screen (§5) runs as soon as a playtest key is available in the environment.
- C, D, E and F need small switch PRs (Bobby), e.g. eval options or env vars that reach `JevIntent.questions/3`, `state/2` and the label sets.
