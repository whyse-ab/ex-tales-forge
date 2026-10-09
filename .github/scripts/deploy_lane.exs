# Picks the deploy lane of a merge to main (decision 2026-10-09, "A fast deploy
# lane for admin work"). Plain `elixir`, no deps or compile needed:
#
#   elixir .github/scripts/deploy_lane.exs --sha <merge sha> --production <sha production runs>
#   elixir .github/scripts/deploy_lane.exs --files lib/a.ex priv/team/data.json
#
# The logic is in TalesForge.DeployLanes and TalesForge.DeployLanes.CLI (lib/),
# where Credo, Dialyzer and the tests cover it; the lists are in
# .github/deploy-lanes.txt.
root = Path.expand("../..", __DIR__)
Code.require_file("lib/ex_tales_forge/deploy_lanes.ex", root)
Code.require_file("lib/ex_tales_forge/deploy_lanes/cli.ex", root)
File.cd!(root)
TalesForge.DeployLanes.CLI.main(System.argv())
