# Survey definitions

The founder survey page (`/admin/survey`, `TalesForge.Survey.Source`) reads
`docs/<id>.json` from **tales-forge-docs main** through the GitHub Contents API
(server `GITHUB_DOCS_TOKEN`, cached 60 s). A wording change is a docs commit;
no deploy needed. `TALES_FORGE_DOCS_PATH` (a local docs checkout) wins in
development.

The files here are **fallback snapshots** shipped in the release. They are used
when GitHub can't be reached, the token is missing, or the docs copy fails
validation (the page then shows an admin error with every problem). Refresh a
snapshot when you change a survey's questions:

    cp ../tales-forge-docs/docs/founder-survey-3.json priv/surveys/
    cp ../tales-forge-docs/docs/founder-survey-4-intent.json priv/surveys/

Every `docs/*survey*.json` is discovered (one directory listing, cached 60 s;
the snapshots here are listed when that fails). Each survey is at
`/admin/surveys/<id>`, results at `/admin/surveys/<id>/results`; `/admin/survey`
shows one tab per survey with `"active": true` that is not closed, with the
founder's status on each, and `/admin/surveys` lists every survey with each
founder's status. Config `:current_survey` is only the fallback when no
survey is active.

## Format (`"format": 1`)

Top level:

| Key | Required | Meaning |
| --- | --- | --- |
| `format` | yes | Always `1`. |
| `id` | yes | Survey id, `a-z0-9-`. One response per user per id. Never change it for a live survey. |
| `version` | yes | Bump when a question's meaning changes. Each answer records the version it was given under; the exact file is stored (by SHA-256) in `survey_definitions`. |
| `status` | no | `draft` (answerable, banner, answers flagged as draft), `open`, or `closed` (read-only). Default `draft`. |
| `active` | no | `true` makes the survey a tab on `/admin/survey` (unless `closed`). Default `false`: still reachable at `/admin/surveys/<id>`, results stay in the admin. |
| `tab` | no | Short tab label; default `title`. |
| `title`, `intro` | title yes | Markdown allowed in `intro`. |
| `estimated_minutes` | no | Shown under the title. |
| `playtest_base_url` | with excerpts | Excerpts link to `<base>/<run_id>#turn-<N>`. |
| `latest_findings` | no | `{ "title", "markdown", "placeholder": true/false }`; a placeholder is shown as such. |
| `lists` | no | Named string lists, used as `"@name"` in `rows`, `columns` and `options`. Excerpts are rated on `lists.rating`. |
| `notes`, `how_we_use` | no | Markdown strings for the readable `.md` and the admin; not shown in the survey. |
| `sections` | yes | `{ "id", "title", "persona"?, "markdown"?, "questions": [...] }`. A `persona` groups answers in the results and the Markdown export. |

Questions: `id` (stable, `a-z0-9-`), `number` ("Q7"), `type`, `title`, `text`
(markdown), `required`, `role` (`keywords`, `archetypes`: labels in the export)
and `follow_ups` (`[{ "id", "label", "role"? }]`, optional short text; roles
`synonym` and `not_meaning` label the export). By type:

| `type` | Extra keys |
| --- | --- |
| `single` | `options`, optional `option_labels` |
| `checkboxes` | `options`, `other: true` for an "Other" text field, optional `option_labels` |
| `scale` | `min`, `max` (≤ 10 apart), `min_label`, `max_label` |
| `grid` | `rows`, `columns`, `multi` (checkboxes per row), `numeric` (column *i* = *i* points; mean per row) |
| `text` | `long: true` for a paragraph |
| `excerpt` | `run_id` (UUID), `turn`, `jev_score` (1–5), `jev_scale`, `character`, `context`, `player`, `game`, `why_hint`; rated on `lists.rating` with a "Why?" field |

`option_labels` (optional, `single` and `checkboxes`): `{ "<option text>": { "<label>":
"<value>" or null, ... } }`, every key one of the options. Founders never see it; the
results page shows each option's labels under its bar, the CSV gets a `"<question>: labels"`
column with the chosen option's labels as JSON, and the Markdown summary lists them after
each option. Used by `founder-survey-4-intent` to map each suggested reading to intent labels
(action, target, now or later, deferred action and target).

Answers are stored by option *text*. If you reword an option, older answers
still count, listed as "(earlier wording)" in the results; bump `version` if
the meaning changed.
