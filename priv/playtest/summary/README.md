# Playtest summary (admin playtest page)

The founder-readable summary on top of `/admin/playtest` comes from two files here
(`TalesForge.Playtest.Summary`):

- `summary.md`: plain-language Markdown. Above the `<!-- batches -->` line: what we test
  and how. Below it: the main findings. Link example runs as `/admin/playtest/<run id>`.
- `batches.json`: one entry per batch, oldest first.

## Adding a batch

Append an entry to `batches.json` with at least `id`, `title`, `date`, `game` (what the
game looked like), `changes` (what changed since the batch before) and, for a
`TalesForge.Playtest.Series` batch, `series` (and `variant` if only one arm counts) and
`runs` (planned). Runs, scores, best and worst runs, cost and commit then fill in live from
the series runs on the server. Once the written analysis lands, add `analysis` (its URL),
the `overall` and per-persona `hook_by_turn_2` and `brush_off` rates, and the per-persona
numbers, so servers without the runs (production) show them too. Then update the findings
in `summary.md`.

Write for founders: plain words, no code names, no jargon.
