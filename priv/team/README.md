# Founders' page data

`data.json` is a snapshot of tales-forge-docs `docs/team-page/data.json`, the
numbers behind the founders' page at `/team` (`TalesForgeWeb.TeamLive`). The
copy comes from `docs/team-page/content.md` in the same folder.

It is read **at compile time** by `TalesForge.TeamPage` (`@external_resource`):
no file or network IO on a request, a broken file fails the build and CI
instead of the page, and the tests check the exact file that ships. A `null`
or missing value shows as "not measured yet"; never put a guess in.

To refresh the numbers, copy the docs file and open a PR:

    cp ../tales-forge-docs/docs/team-page/data.json priv/team/data.json

The page shows `_about.as_of` in its footer ("Numbers as of ...").
