# Contributing to ex-tales-forge

Read `AGENTS.md` first: it has the stack, the deploy lanes and the coding rules. This file holds the writing rules for people and agents.

## Language: positive framing and ASD-STE100

Decision: tales-forge-docs `docs/decisions.md`, 2026-10-10, "Positive framing and ASD-STE100 language standard" (Fredrik).

**1. Say confidence, not doubt.** In the UI, playtest reports, scores, prompts that show in reports, and docs, write "confidence" or "certainty". Do not write "unsure", "uncertain", "uncertainty" or "unsureness". Give the positive quantity directly. Do not use minimized negatives ("not unlikely", "fewer failures") or double negatives.

| Write | Not |
|---|---|
| `4.21/5 · confident 70%` | `4.21/5 · unsure 30%` |
| `3 low-confidence turns` | `3 unsure turns` |
| `Jev had low confidence here.` | `Jev was very unsure here.` |
| `9 of 10 checks pass.` | `Only 1 check fails.` |
| `The result is likely.` | `The result is not unlikely.` |

**2. Code, comments, moduledocs and docs use ASD-STE100 Simplified Technical English.**

- Short sentences: 20 words or fewer for an instruction, 25 for a description.
- One instruction in one sentence. Start an instruction with the verb.
- Active voice. Name the actor.
- Use approved words with one meaning. Use the same word for the same thing every time.

| Write | Not |
|---|---|
| `Start the poller. Then read the snapshot.` | `The snapshot should be read once the poller has been started.` |
| `The scorer writes one row for each turn.` | `A row is written per turn by the scorer.` |
| `@doc "Returns the confident share (0 to 1)."` | `@doc "Basically gives you roughly how sure-ish Jev was."` |

Old names (for example `unsure_share`, `unsure_pct`) change to the confidence form when you touch them. A separate rename PR does the rest. Do not change the GM, Jev or intent prompts for wording only: a prompt change needs its own decision, and the baseline GM prompt golden test stays byte-identical.
