# Jev intent: DOE screen results (reduced 2² on A, B)

2026-11-23, Europe/Stockholm. Plan: `2026-11-23-jev-doe-screen.md` §5. Code at `a5a0d2a6`, `jev-1.13.0`. Tune split only. The holdout was not run. Aggregate numbers only.

## Setup

- Runs: R1 (baseline, v1 catalogue, no self-check), R2 (A+ `JEV_CATALOGUE_V2=on`), R3 (B+ `JEV_SELF_CHECK=on`), R4 (A+ B+). R1b and R1c are baseline replicates.
- Flags: `mix intent.eval --split tune --readers jev --timeout-ms 1500 --concurrency 4`. Each run and replicate had its own `--cache` dir, so every run is a fresh network read.
- 247-reviewed numbers: the same cached replies re-scored on a reviewed-only copy of the tune fixture, with no key and no new calls.
- Latency: wall time per Jev HTTP call, measured on the eval machine by a scratch-only timing tap. The tap is not in this PR and does not change requests. The eval writes no `ai_calls` rows for Jev.
- Cost: $0.30 total for 1,967 calls (6 × 327 plus a 5-item smoke test).
- Clarify % is the share of items in the `clarify` decision band (act_min 0.70, ask_below 0.45, raw 0.45).
- Safety recall and false positives come from the report's safety section.

## 247 reviewed tune items

| Run | A | B | action % | material err % | target % | skill % | deferred F1 | safety recall % | false pos % | ECE | clarify % | timeouts | p50 ms | p95 ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| R1 | − | − | 94.7 | 1.6 | 90.2 | 96.4 | 0.810 | 100.0 | 0.0 | 0.033 | 13.0 | 0 | 66 | 139 |
| R1b | − | − | 95.1 | 1.2 | 89.7 | 96.8 | 0.810 | 100.0 | 0.0 | 0.028 | 13.8 | 0 | 64 | 126 |
| R1c | − | − | 94.7 | 2.0 | 89.1 | 96.4 | 0.815 | 100.0 | 0.0 | 0.023 | 14.6 | 0 | 64 | 126 |
| R2 | + | − | 98.0 | 1.2 | 90.0 | 95.1 | 0.800 | 100.0 | 0.0 | 0.049 | 16.2 | 0 | 70 | 142 |
| R3 | − | + | 94.7 | 1.6 | 90.1 | 96.4 | 0.810 | 100.0 | 0.0 | 0.023 | 13.8 | 0 | 65 | 147 |
| R4 | + | + | 98.0 | 1.2 | 89.5 | 95.1 | 0.775 | 100.0 | 0.0 | 0.048 | 17.0 | 0 | 71 | 152 |

## All 327 tune items (80 are drafts)

| Run | A | B | action % | material err % | target % | skill % | deferred F1 | safety recall % | false pos % | ECE | clarify % | timeouts | p50 ms | p95 ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| R1 | − | − | 90.5 | 4.0 | 87.6 | 96.9 | 0.790 | 92.5 | 0.0 | 0.032 | 12.8 | 0 | 66 | 139 |
| R1b | − | − | 91.7 | 3.7 | 87.6 | 97.2 | 0.790 | 92.5 | 0.0 | 0.031 | 13.5 | 0 | 64 | 126 |
| R1c | − | − | 91.1 | 4.3 | 87.6 | 96.6 | 0.786 | 92.5 | 0.0 | 0.030 | 13.8 | 0 | 64 | 126 |
| R2 | + | − | 93.9 | 3.7 | 88.2 | 95.7 | 0.771 | 92.5 | 0.0 | 0.023 | 16.5 | 0 | 70 | 142 |
| R3 | − | + | 90.5 | 4.0 | 88.7 | 96.6 | 0.790 | 92.5 | 0.0 | 0.038 | 13.5 | 0 | 65 | 147 |
| R4 | + | + | 93.9 | 4.0 | 87.8 | 95.7 | 0.747 | 90.6 | 0.0 | 0.026 | 16.8 | 0 | 71 | 152 |

## Noise, effects, tests

| | 247 reviewed | all 327 |
|---|---|---|
| Baseline replicate range, action % | 94.7–95.1 (sd 0.23 pp) | 90.5–91.7 (sd 0.60 pp) |
| Baseline replicate range, material error % | 1.2–2.0 (sd 0.40 pp) | 3.7–4.3 (sd 0.30 pp) |
| Items flipping right/wrong between replicates | 1–3 | 4 |
| Effect A on action (pp) | **+3.2** | **+3.1** |
| Effect B on action (pp) | −0.1 | −0.3 |
| Effect AB on action (pp) | +0.1 | +0.3 |
| Effect A / B / AB on material error (pp) | −0.4 / 0.0 / 0.0 | −0.15 / +0.15 / +0.15 |
| McNemar R2 vs R1 / R1b / R1c (exact) | p = 0.021 / 0.039 / 0.021 (1 vs 8–9 discordant) | p = 0.003 / 0.092 / 0.022 |
| McNemar R3 vs baselines | p = 1.0 | p ≥ 0.125 |

Jev is not deterministic: same request, different reply on 1–4 items per run. Only effect A on action accuracy is larger than the replicate noise. B, AB and every material-error effect are within noise.

## Caveat on A: scoring leniency (see strict re-score below)

Catalogue v2 is scored through `JevIntent.v1_actions/1`. On the reviewed set, 5 of R2's 9 extra right answers are the v2 type `work`. `work` maps to *either* `freeform` or `wait`, so it is credited whenever the gold allows `freeform` or `wait`. That includes items whose gold action is `speak`, `move` or `other`.

With those 5 removed, A is +4 / −1 items, McNemar p ≈ 0.38. The other gains are `speak` read correctly (3) and `rest` for a wait (1).

So the A gain is **not yet evidence** that v2 reads intent better. It may come from the looser mapping.

A also costs more: about +$0.00007 per call (+54 %), and its ECE on the 247 set is worse (0.049 vs 0.023–0.033) under the v1-fitted calibration.

## Not seen

No timeouts or errors at 1.5 s (p95 ≤ 152 ms). Safety recall 100 % on reviewed items and 0 false positives in every run. Safety recall on all 327 was 92.5 % (R4: 90.6 %, one draft item).

## Strict re-score of catalogue v2 (2026-11-23, cached replies, no new calls)

Rule: a v2 action with no single v1 twin (`work`, `give`, `equip`, `rest`, `none_fits`) is right only if the **gold action** is one of its v1 mappings. It no longer counts as right through `acceptable_actions` (freeform/wait). v1 runs are unchanged. Material error and ECE use the same rule. Scratch-only scoring switch, not in this PR.

**247 reviewed**

| Run | A | B | action % | material err % | ECE | clarify % |
|---|---|---|---|---|---|---|
| R1 | − | − | 94.7 | 1.6 | 0.033 | 13.0 |
| R1b | − | − | 95.1 | 1.2 | 0.028 | 13.8 |
| R1c | − | − | 94.7 | 2.0 | 0.023 | 14.6 |
| R2 | + | − | 96.0 | 3.2 | 0.038 | 16.2 |
| R3 | − | + | 94.7 | 1.6 | 0.023 | 13.8 |
| R4 | + | + | 96.0 | 3.2 | 0.035 | 17.0 |

**All 327**

| Run | A | B | action % | material err % | ECE | clarify % |
|---|---|---|---|---|---|---|
| R1 | − | − | 90.5 | 4.0 | 0.032 | 12.8 |
| R1b | − | − | 91.7 | 3.7 | 0.031 | 13.5 |
| R1c | − | − | 91.1 | 4.3 | 0.030 | 13.8 |
| R2 | + | − | 91.4 | 6.1 | 0.040 | 16.5 |
| R3 | − | + | 90.5 | 4.0 | 0.038 | 13.5 |
| R4 | + | + | 91.4 | 6.4 | 0.032 | 16.8 |

| Effect (pp) | 247 reviewed | all 327 |
|---|---|---|
| A on action | +1.2 | +0.6 |
| A on material error | **+1.6 (worse)** | **+2.25 (worse)** |
| A on clarify | +2.8 | +3.2 |
| B on action / material | −0.1 / 0.0 | −0.3 / +0.15 |
| AB on action | +0.1 | +0.3 |
| McNemar R2 vs R1 / R1b / R1c / R3 | p = 0.375 / 0.625 / 0.375 / 0.375 (1 vs 3–4) | p = 0.51 / 1.0 / 1.0 / 0.55 |

**Verdict:** scored strictly, catalogue v2 is not better on action. It is worse on material error (R2/R4 at 3.2 % on reviewed items, over the 3 % target). The earlier +3.2 points came from lenient mapping. Keep v2 off. Judging v2 fairly needs v2 gold labels.

## Why clarify is 13–17 % (and was "0 %" on 8 Oct)

Clause that fires first, baseline runs, 247 reviewed, current calibration map:

| Run | clarify | plausible runner-up of another class (≥ 0.25) | raw confidence < 0.45 (`ask_below_raw`) | goods/coins < act_min | calibrated < ask_below |
|---|---|---|---|---|---|
| R3 (prod-like) | 34 (13.8 %) | 18 | 15 | 1 | 0 |
| R1 | 32 | 17 | 13 | 2 | 0 |
| R1b | 34 | 19 | 14 | 1 | 0 |
| R1c | 36 | 20 | 15 | 1 | 0 |

- **Not calibration drift.** The current map fits today's replies well: ECE 0.023 (R3), 0.023–0.033 (R1–R1c). Raw ECE is 0.205, the same as the 8 Oct raw ECE (0.188, 4 s timeout). The calibrated `ask_below` clause fires on **0** items.
- **The cause is the band rules.** The raw-confidence check (`ask_below_raw 0.45`, PR #92, 2026-10-09) was added *after* the 8 Oct baseline. It accounts for about 45 % of the clarifies. The plausible-runner-up rule (raw action probabilities ≥ 0.25 in another class) accounts for about 55 %.
- Both rules read **raw** Jev probabilities, which no calibration map touches. 30 % of reads have raw confidence < 0.5 (R3 histogram: <0.3: 3, 0.3–0.4: 16, 0.4–0.5: 27).
- **The asks are mostly not needed.** Only 9–17 % of the clarified reads were actually wrong.
- The 8 Oct "clarify 0 %" came from the shadow/on-arm observation and an eval version without the raw check. It is not comparable.

## Calibration refit (proposal only)

Isotonic PAV, `min_block` 15, fitted on R3 (v1, self-check on), 247 reviewed tune items:

| | ECE |
|---|---|
| raw | 0.205 |
| current map `jev-intent-cal-2026-10-08-v1`, on R3 | 0.023 |
| refit, in-sample | 0.025 |
| refit, 5-fold CV | 0.027 |
| refit applied to R1 / R1b / R1c | 0.032 / 0.028 / 0.031 (current 0.033 / 0.028 / 0.023) |

The refit is practically the same map and is **not** better. Recommendation: keep `priv/intent/calibration.json` as it is. The proposed file, for the record only:

```json
{"fitted_on": "tune", "method": "isotonic (PAV), action-correct on raw Jev confidence", "min_block": 15, "n": 247,
 "points": [[0.0, 0.0625], [0.4118, 0.8113], [0.6177, 0.9206], [0.9244, 0.9927], [1.0, 0.9927]],
 "version": "jev-intent-cal-2026-11-23-doe-proposal"}
```

## Threshold sweep (offline, cached replies)

Grid: `act_min` {0.5, 0.6, 0.7, 0.8} × `ask_below` {0.2–0.45} × `ask_below_raw` {0, 0.2, 0.3, 0.4, 0.45} × plausible {0.25, 0.3, 0.35, 0.4, 0.5, off} × map {current, refit}. Evaluated on 4 baseline runs (R3, R1, R1b, R1c).

Constraint: clarify ≤ 4 % in **every** run, and played material error (wrong consequence class played without a question, share of all items) ≤ 3 %. Ranked by lowest played material error, then lowest played-wrong.

The plausible threshold is a module attribute today. The sweep made it an option in a scratch copy only.

**Proposed thresholds:** `act_min 0.80`, `ask_below 0.45` (unchanged; it never binds), `ask_below_raw 0.30` (was 0.45), plausible runner-up **0.40** (was 0.25). Current calibration map. The refit map gives identical bands.

| 247 reviewed | defaults (R3 / R1 / R1b / R1c) | proposed (R3 / R1 / R1b / R1c) |
|---|---|---|
| clarify % | 13.8 / 13.0 / 13.8 / 14.6 | **2.8 / 3.2 / 3.2 / 3.2** |
| played material error % | 0.4 / 0.4 / 0.4 / 0.4 | 1.2 / 1.2 / 0.8 / 0.8 |
| played wrong action % | 3.6 / 3.6 / 3.6 / 2.8 | 4.9 / 4.9 / 4.5 / 4.0 |
| asks that were justified % | 12 / 13 / 9 / 17 | 14 / 13 / 13 / 38 |

- Action accuracy (94.7–95.1 %), material error over all reads (1.2–2.0 %), ECE and safety are unchanged by thresholds. Safety classification and the nefarious decline sit outside the bands.
- On all 327 tune items, the proposal gives clarify 3.7–4.0 % and played material error 3.4–3.7 %. That is above 3 %, driven by the 80 unreviewed drafts (their all-reads material error is 4.0 %).
- Trade-off: about 30 fewer questions per 247 turns, for about 2 more material errors played.
- Shipping any of this is a code PR by Bobby (an option for the plausible threshold plus new defaults), with Fredrik's merge, and holdout confirmation on Fredrik's go.

Cost of this step: $0.00 (no new Jev calls). Screen total so far: $0.30.

## Next

1. Keep catalogue v2 off. If v2 is wanted, label v2 gold (`work`/`give`/`equip`/`none_fits`, `then`, manner).
2. Bobby (switch PR, already requested): make `plausible` configurable, consider the proposed thresholds, and add C–F switches for the 16-run screen.
3. Review the 80 draft items. They push all-327 material error over 3 %.
4. Holdout once, on Fredrik's go, on the final setup and thresholds.
