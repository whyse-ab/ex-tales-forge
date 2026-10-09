# Playtest summary (admin playtest page)

The founder-readable summary on top of `/admin/playtest` comes from two files here
(`TalesForge.Playtest.Summary`):

- `summary.md`: plain-language Markdown. Above the `<!-- batches -->` line: what we test
  and how. Below it: the main findings. Link example runs with their full playtest URL,
  `https://tales-forge-playtest.fly.dev/admin/playtest/<run id>` (add `#turn-<n>` to open a
  turn), so the links also work on production, which has no runs.
- `batches.json`: one entry per batch, oldest first.

## Adding a batch

Append an entry to `batches.json` with at least `id`, `title`, `date`, `game` (what the
game looked like), `changes` (what changed since the batch before) and, for a
`TalesForge.Playtest.Series` batch, `series` (and `variant` if only one variant counts;
`arm` too for one arm of a comparison whose run notes say `arm=<arm>` after the variant),
`"status": "running"` and `runs` (planned). Runs, scores, best and worst runs, cost and
commit then fill in live from the series runs on the server, and the card says
"N of M runs done so far". Once the written analysis lands (not before: the link would
404):

- set `"status": "done"`, `runs` to the number of runs the numbers rest on (the
  completed ones) and `planned_runs` to the plan, so a short batch says
  "23 of 25 planned runs done". Say in `notes` how many runs were played and why any
  were left out, so the counts add up;
- add `analysis` (its URL), the `overall` and per-persona `hook_by_turn_2` and
  `brush_off` rates where the analysis has them, and the per-persona numbers, so a server
  without the runs shows them too;
- update the findings in `summary.md`.

Write for founders: plain words, no code names, no jargon.
