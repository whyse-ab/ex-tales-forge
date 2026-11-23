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

## Caveat on A: scoring leniency

Catalogue v2 is scored through `JevIntent.v1_actions/1`. On the reviewed set, 5 of R2's 9 extra right answers are the v2 type `work`. `work` maps to *either* `freeform` or `wait`, so it is credited whenever the gold allows `freeform` or `wait`. That includes items whose gold action is `speak`, `move` or `other`.

With those 5 removed, A is +4 / −1 items, McNemar p ≈ 0.38. The other gains are `speak` read correctly (3) and `rest` for a wait (1).

So the A gain is **not yet evidence** that v2 reads intent better. It may come from the looser mapping.

A also costs more: about +$0.00007 per call (+54 %), and its ECE on the 247 set is worse (0.049 vs 0.023–0.033) under the v1-fitted calibration.

## Not seen

No timeouts or errors at 1.5 s (p95 ≤ 152 ms). Safety recall 100 % on reviewed items and 0 false positives in every run. R4 on all 327 dropped to 90.6 % (one draft item).

## Next

1. Decide how `work` / `give` / `equip` are scored against v1 gold (strict single mapping, or gold labels for v2), then re-score the cached R2/R4 replies. This costs nothing.
2. B (self-check) has no effect on intent. Keep or drop it on its own merits (self-check accuracy).
3. Switch PRs for C–F, then the 16-run screen.
4. Holdout only on Fredrik's go.
