# Decides the security deploy lane (ex-tales-forge docs/decisions.md,
# 2026-10-11 "Security-bump lane"). Plain `elixir`, no deps or compile needed:
#
#   elixir .github/scripts/security_lane.exs pr --base <sha> --head <sha> --pr pr.json --ci success
#   elixir .github/scripts/security_lane.exs main --sha <merge sha> --production <sha> --pr pr.json --ci success
#
# The rules are in TalesForge.DeployLanes.Security and
# TalesForge.DeployLanes.SecurityCLI (lib/), where Credo, Dialyzer and the
# tests cover them.
root = Path.expand("../..", __DIR__)
Code.require_file("lib/ex_tales_forge/deploy_lanes.ex", root)
Code.require_file("lib/ex_tales_forge/deploy_lanes/security.ex", root)
Code.require_file("lib/ex_tales_forge/deploy_lanes/security_cli.ex", root)
Code.require_file("lib/ex_tales_forge/deploy_lanes/security_audit.ex", root)
File.cd!(root)

case System.argv() do
  [cmd | _] when cmd in ["bump", "unlock-neighbors", "lock-version", "reaches"] ->
    TalesForge.DeployLanes.SecurityAudit.main(System.argv())

  argv ->
    TalesForge.DeployLanes.SecurityCLI.main(argv)
end
