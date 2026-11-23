# Plan: move Tales Forge board ideas to GitHub Issues

Hobby-mode work list step 7. This is a plan only: it changes no Issues, labels,
webhooks or board state. Carrying it out needs Fredrik's go in his own words.

## Goal

Move the open Tales Forge board work into GitHub Issues in `whyse-ab/ex-tales-forge`,
then archive the board (read-only, not deleted) and remove the board webhooks.
Fredrik can then track work in Issues, with labels `idea`, `bug` and `next`.

## Source

Board app `whyse-flow-tales-forge-prod`, last counted on 2026-11-21:

- 169 cards in total: 101 done, **57 ideas**, 5 refining, 4 parked, 2 check
- Latest board update then: 2026-10-27

Export the 57 open ideas, plus cards still in refining, parked or check if they
are not done, and the known bugs already named in `docs/hobby-mode.md`:

- brass key false premise
- untrained roll label
- two-turn
- hang
- clarification crash

Before the export, recount the board so the numbers are current.

## Labels

Create (or reuse) on `whyse-ab/ex-tales-forge`:

| Label | Use |
|---|---|
| `idea` | A board idea, including refining and parked ideas |
| `bug` | A known bug |
| `next` | The small set Fredrik actually wants to pick up next |

Do not auto-tag everything as `next`. After the export, Fredrik marks `next`
himself, or says which issues should get it.

## Issue shape

One GitHub issue per open card (and per known bug that has no card).

- Title: the card title
- Body: the card text, plus a line with the board card id and column so the
  archive stays traceable
- Label: `idea` or `bug` as above
- No assignee unless Fredrik names one

If a card already has a matching open issue (same title, or a link on the
card), add the label and a comment instead of opening a duplicate.

Done cards (101) stay on the board only. They are not copied to Issues.

## Then archive, don't delete

1. Confirm every exported card has an issue URL.
2. Remove the board webhooks (the board should no longer notify bots). Name
   the webhook endpoints in the change log; never write secrets.
3. Archive the board so it is read-only. Do **not** delete the board app or
   its database. That would be a separate delete, like hobby-mode step 8.

## What Fredrik must OK

- The export itself (this plan is not that OK)
- Removing the webhooks
- Archiving the board

Access needed at that time (names only): whatever token or session can read
the board API today, and permission to create issues and labels in
`whyse-ab/ex-tales-forge`. The default `GITHUB_TOKEN` on Actions can open
issues once a workflow exists; the first export can also be done by hand
with `gh`.
