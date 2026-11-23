# Jev intent: full DOE screen, 2^(5−1) resolution V on A–E

2026-11-23, Europe/Stockholm. Follows `2026-11-23-jev-doe-screen.md` and `2026-11-23-jev-doe-results.md`. Code at main `5f78121` (eval switches from #613). Model `jev-1.13.0`. **Tune split only**; the holdout was not run. Aggregate numbers only.

## Design

| Factor | − | + | How |
|---|---|---|---|
| A catalogue | v1 | v2 | `JEV_CATALOGUE_V2=on` |
| B self-check | off | on | `JEV_SELF_CHECK=on` (prod has it on) |
| C skill split | off | on | `--skill-split` |
| D context window | 800 / 600 chars | 1600 / 1200 | `--narration-chars 1600 --player-chars 1200` |
| E last player actions | not sent | up to 3 sent | `--last-actions` |

- F (wording) is not run, because no switch exists yet.
- 16 runs F01–F16, generator **E = ABCD** (defining relation I = ABCDE). Main effects are aliased only with 4-factor interactions, and 2-factor interactions only with 3-factor ones.
- Baseline (all −) is outside the half fraction, so it was run separately:
  - BL1 and BL2 are new runs.
  - oldR1/R1b/R1c are the three baseline runs from 05:2x. Their requests are byte-identical on #613: they were re-scored from cache with no misses.
  - That gives 5 replicates for noise.
- Settings: `--split tune --readers jev --timeout-ms 1500 --concurrency 4`, with one `--cache` dir per run.
- Every run is scored with the bands as they are today (v1) and re-scored from cache with `--clarify-v2` (0.80 / 0.45 / 0.30 / runner-up 0.40), on the 247 reviewed and on all 327 tune items.
- **Strict scoring** throughout: a v2 action with no single v1 twin (`work`, `give`, `equip`, `rest`, `none_fits`) is right only if the gold action maps to it. This is a scratch-only scoring switch, not in the repo.
- Latency is the wall time of each Jev HTTP call, measured with a scratch-only timing tap.

## Results

### 247 reviewed

| Run | A cat v2 | B self-check | C split | D 1600/1200 | E last acts | action % | material % | clarify v1 % | clarify v2 % | p50 ms | p95 ms | timeouts |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| F01 | − | − | − | − | + | 96.0 | 0.8 | 12.1 | 2.4 | 61 | 110 | 0 |
| F02 | + | − | − | − | − | 95.1 | 4.0 | 17.8 | 4.5 | 71 | 151 | 0 |
| F03 | − | + | − | − | − | 95.1 | 1.6 | 13.4 | 2.8 | 67 | 132 | 0 |
| F04 | + | + | − | − | + | 94.7 | 4.9 | 15.0 | 4.5 | 78 | 130 | 0 |
| F05 | − | − | + | − | − | 95.1 | 1.6 | 14.2 | 2.0 | 63 | 106 | 0 |
| F06 | + | − | + | − | + | 94.7 | 4.5 | 14.6 | 5.7 | 70 | 130 | 0 |
| F07 | − | + | + | − | + | 95.5 | 0.8 | 12.1 | 2.0 | 63 | 143 | 0 |
| F08 | + | + | + | − | − | 95.5 | 3.6 | 17.0 | 4.9 | 70 | 115 | 0 |
| F09 | − | − | − | + | − | 94.7 | 1.6 | 12.6 | 3.2 | 64 | 131 | 0 |
| F10 | + | − | − | + | + | 94.7 | 4.9 | 13.8 | 4.9 | 67 | 133 | 0 |
| F11 | − | + | − | + | + | 96.0 | 0.8 | 12.1 | 2.4 | 61 | 89 | 0 |
| F12 | + | + | − | + | − | 95.1 | 4.0 | 16.2 | 4.9 | 70 | 148 | 0 |
| F13 | − | − | + | + | + | 95.5 | 0.8 | 13.0 | 1.6 | 60 | 88 | 0 |
| F14 | + | − | + | + | − | 96.0 | 3.2 | 17.0 | 5.3 | 75 | 123 | 0 |
| F15 | − | + | + | + | − | 95.5 | 1.2 | 12.1 | 2.8 | 61 | 102 | 0 |
| F16 | + | + | + | + | + | 94.3 | 5.3 | 14.6 | 4.9 | 69 | 120 | 0 |
| BL1 | − | − | − | − | − | 95.1 | 1.2 | 15.4 | 2.8 | 61 | 109 | 0 |
| BL2 | − | − | − | − | − | 95.5 | 1.2 | 13.8 | 2.8 | 64 | 132 | 0 |
| oldR1 | − | − | − | − | − | 94.7 | 1.6 | 13.0 | 3.2 | 66 | 139 | 0 |
| oldR1b | − | − | − | − | − | 95.1 | 1.2 | 13.8 | 3.2 | 64 | 126 | 0 |
| oldR1c | − | − | − | − | − | 94.7 | 2.0 | 14.6 | 3.2 | 64 | 126 | 0 |

**Effects (247 reviewed)** — effect = mean(+) − mean(−) over the 16 runs. Noise: replicate range over 5 baseline runs; SE(effect) = sd/2.

| Response | replicate range | sd | flag threshold (max(range, 2·SE)) | A | B | C | D | E | 2FIs above threshold |
|---|---|---|---|---|---|---|---|---|---|
| action | 94.7–95.5 | 0.33 | 0.80 | -0.41 | -0.01 | +0.09 | +0.01 | -0.09 | none |
| material | 1.2–2.0 | 0.36 | 0.80 | **+3.15** | +0.10 | -0.20 | +0.00 | +0.25 | AE +0.95 |
| clar_v1 | 13.0–15.4 | 0.91 | 2.40 | **+3.05** | -0.32 | +0.20 | -0.60 | -1.62 | none |
| clar_v2 | 2.8–3.2 | 0.22 | 0.40 | **+2.55** | -0.05 | -0.05 | +0.15 | -0.25 | AC +0.55 |
| p95 | 109.0–139.0 | 11.10 | 30.00 | +18.62 | +0.88 | -12.12 | -10.38 | -8.12 | none |

Best run on reviewed action %: **F01**.
- McNemar F01 vs BL1: baseline-only right 0, F01-only right 2, exact p = 0.500
- McNemar F01 vs BL2: baseline-only right 0, F01-only right 1, exact p = 1.000
- McNemar F01 vs oldR1: baseline-only right 0, F01-only right 3, exact p = 0.250
- McNemar F01 vs oldR1b: baseline-only right 0, F01-only right 2, exact p = 0.500
- McNemar F01 vs oldR1c: baseline-only right 0, F01-only right 3, exact p = 0.250

### all 327

| Run | A cat v2 | B self-check | C split | D 1600/1200 | E last acts | action % | material % | clarify v1 % | clarify v2 % | p50 ms | p95 ms | timeouts |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| F01 | − | − | − | − | + | 92.0 | 3.4 | 13.1 | 3.4 | 61 | 110 | 0 |
| F02 | + | − | − | − | − | 91.1 | 7.0 | 17.7 | 5.2 | 71 | 151 | 0 |
| F03 | − | + | − | − | − | 91.4 | 4.0 | 13.1 | 3.7 | 67 | 132 | 0 |
| F04 | + | + | − | − | + | 90.8 | 7.6 | 16.2 | 4.9 | 78 | 130 | 0 |
| F05 | − | − | + | − | − | 91.4 | 4.0 | 13.5 | 2.8 | 63 | 106 | 0 |
| F06 | + | − | + | − | + | 91.1 | 7.3 | 15.3 | 6.4 | 70 | 130 | 0 |
| F07 | − | + | + | − | + | 90.8 | 3.7 | 12.8 | 3.4 | 63 | 143 | 0 |
| F08 | + | + | + | − | − | 91.4 | 6.7 | 17.1 | 4.6 | 70 | 115 | 0 |
| F09 | − | − | − | + | − | 91.1 | 4.0 | 12.5 | 4.0 | 64 | 131 | 0 |
| F10 | + | − | − | + | + | 91.1 | 7.6 | 14.7 | 4.9 | 67 | 133 | 0 |
| F11 | − | + | − | + | + | 91.4 | 3.7 | 13.1 | 3.1 | 61 | 89 | 0 |
| F12 | + | + | − | + | − | 91.1 | 7.0 | 16.8 | 5.8 | 70 | 148 | 0 |
| F13 | − | − | + | + | + | 91.7 | 3.7 | 13.8 | 2.8 | 60 | 88 | 0 |
| F14 | + | − | + | + | − | 91.7 | 6.4 | 16.8 | 6.7 | 75 | 123 | 0 |
| F15 | − | + | + | + | − | 91.7 | 3.7 | 12.5 | 2.8 | 61 | 102 | 0 |
| F16 | + | + | + | + | + | 90.5 | 7.6 | 16.2 | 6.4 | 69 | 120 | 0 |
| BL1 | − | − | − | − | − | 90.8 | 3.7 | 14.7 | 3.4 | 61 | 109 | 0 |
| BL2 | − | − | − | − | − | 91.1 | 3.7 | 13.5 | 3.4 | 64 | 132 | 0 |
| oldR1 | − | − | − | − | − | 90.5 | 4.0 | 12.8 | 4.0 | 66 | 139 | 0 |
| oldR1b | − | − | − | − | − | 91.7 | 3.7 | 13.5 | 4.0 | 64 | 126 | 0 |
| oldR1c | − | − | − | − | − | 91.1 | 4.3 | 13.8 | 3.7 | 64 | 126 | 0 |

**Effects (all 327)** — effect = mean(+) − mean(−) over the 16 runs. Noise: replicate range over 5 baseline runs; SE(effect) = sd/2.

| Response | replicate range | sd | flag threshold (max(range, 2·SE)) | A | B | C | D | E | 2FIs above threshold |
|---|---|---|---|---|---|---|---|---|---|
| action | 90.5–91.7 | 0.44 | 1.20 | -0.34 | -0.26 | +0.04 | +0.04 | -0.19 | none |
| material | 3.7–4.3 | 0.27 | 0.60 | **+3.38** | +0.08 | -0.15 | +0.00 | +0.23 | none |
| clar_v1 | 12.8–14.7 | 0.69 | 1.90 | **+3.30** | +0.05 | +0.10 | -0.30 | -0.60 | none |
| clar_v2 | 3.4–4.0 | 0.30 | 0.60 | **+2.36** | -0.19 | +0.11 | +0.26 | -0.04 | AC +0.71 |
| p95 | 109.0–139.0 | 11.10 | 30.00 | +18.62 | +0.88 | -12.12 | -10.38 | -8.12 | none |


Effects in **bold** exceed the flag threshold, which is the larger of the replicate range and 2·SE. p95 noise is large (range 109–139 ms), and no p95 effect exceeds it.

## Reading

- **A (catalogue v2) is the only real factor, and it is harmful.**
  - Material error rises about 3.2 points on the reviewed items (1.2–2.0 % → 3.2–5.3 %), above the 3 % target.
  - Clarify rises about 3 points with v1 bands and about 2.5 points with v2 bands. With v2 bands, A+ runs sit at 4.5–5.7 %, above the 4 % target.
  - Action accuracy does not improve (−0.4 points).
  - Cost is about +55 % per call.
- **B (self-check), C (skill split) and D (wider context)** have no effect on any response beyond noise.
  - D is effectively untested: only 1 of 327 tune items has player text over 600 chars and none has narration over 800. The D+ request differed from the baseline on 1 item.
- **E (last actions)** has no effect beyond noise. The trend is slightly favourable: material +0.25, clarify v1 −1.6, p95 −8 ms. See the caveat below.
- **Interactions:**
  - AE on material (+0.95, reviewed only) is barely above threshold.
  - AC on clarify v2 (+0.55 / +0.71) is small. Both come from A+ runs.
  - Nothing else exceeds noise.
- **Best run:** F01 (E only), 96.0 % action and 0.8 % material error on reviewed items. F11 ties. McNemar vs each of the 5 baselines: 0 vs 1–3 discordant items, p = 0.25–1.0. **No significant gain.**
- **Clarify v2 bands** hold up across all v1-catalogue runs: 1.6–3.2 % on reviewed items, 2.8–4.0 % on all 327, with no timeouts.

## Caveats

- **E has thin coverage.** Only 153 of 327 tune items carry `recent_turns`, never more than 2 turns, each cut at 120 chars. E+ adds `last_player_actions` (possibly empty) to every request. A null E result means "not tested well", not "no value".
- **D cannot be judged on this fixture.** It needs items with long narration or long player text.
- The 80 draft items still lift all-327 material error to about 3.7 % at baseline.
- The holdout is unspent.

## Cost

$0.96 for 18 new runs (5,886 Jev calls). Re-scoring was free. DOE total today: $1.26.

## Recommendation

1. Keep the prod setup as it is: v1 catalogue, self-check on, no split, 800/600 context.
2. Turn on `JEV_CLARIFY_V2` after one holdout confirmation, on Fredrik's go. The holdout run would use the prod-like setup (B+) with `--clarify-v2`.
3. Drop catalogue v2 unless it gets its own gold labels.
4. Before re-testing D and E, add tune items with long narration and 3-turn histories (a fixture PR, plus labelling).
5. F (wording) needs a text proposal first.

## Holdout confirmation (one-time, 2026-11-23 07:1x Europe/Stockholm)

Fredrik's go, 07:10: "Run the one-time held-back confirmation for the new clarify thresholds."

- **One live run** on the 103-item holdout (`--split holdout --i-mean-it`), prod-like: catalogue v1, self-check on, no split, 800/600, no last actions, `--timeout-ms 1500`, its own cache.
- The same cached replies were scored twice, with today's v1 bands and with `--clarify-v2`. The second scoring ran with no key and made no network calls.
- Strict scoring. Nothing was tuned on these numbers. **The holdout is now spent.**

| Holdout (n = 103) | v1 bands (0.70 / 0.45 / 0.45 / 0.25) | v2 bands (0.80 / 0.45 / 0.30 / 0.40) | Target |
|---|---|---|---|
| Action accuracy | 92.2 % | 92.2 % | ≥ 90 % |
| Material error (all reads) | 4.9 % | 4.9 % | ≤ 3 % |
| Clarify | 18.6 % (19) | **2.9 % (3)** | ≤ 4 % |
| Material error played without a question | 1.0 % (1) | **3.9 % (4)** | ≤ 3 % |
| Wrong action played without a question | 2.9 % (3) | 5.8 % (6) | — |
| Safety recall, 18 attacks | 16 / 18 (0.889) | 16 / 18 (0.889) | ≥ 0.95 |
| False positives, 85 benign | 0 | 0 | ≤ 3 % |
| ECE | 0.051 | 0.051 | ≤ 0.05 |
| Timeouts | 1 | 1 | — |
| p50 / p95 latency | 74 / 164 ms | same replies | — |

Notes:

- One of the two missed attacks is the single timeout, on a prompt-injection item. In live play a timeout falls back to the heuristic, and the player's words are not passed on. The other miss is a prompt injection that Jev read as benign. Jailbreak and nefarious recall are 100 %.
- The bands do not touch safety, so v1 and v2 are identical on safety.
- Material error over all reads (4.9 %) does not depend on the bands. It is above target on the holdout with either set, against 1.2–2.0 % on the reviewed tune items.
- n = 103, so each item is about 1 point. The played-material difference is 1 vs 4 items.

**Verdict:**

- v2 meets the clarify target (2.9 %) and leaves safety unchanged.
- It **misses the played material-error target** on the holdout: 3.9 % against ≤ 3 %, up from 1.0 % with v1.
- So v2 turns about 16 questions per 103 turns into plays, at the price of about 3 more wrong-consequence plays.
- Enabling `JEV_CLARIFY_V2` is therefore a product trade-off for Fredrik, not a clean pass. Any further threshold work needs new tune analysis, and the holdout cannot be reused for it.
