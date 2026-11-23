# The security-fix lane's guard (TalesForge.DeployLanes.SecurityFix). Plain
# `elixir`; the workflows run it from main's checkout, never a pull request's:
#
#   elixir .github/scripts/security_fix.exs <merge|deploy> <base sha> <head sha> facts.json
#
# facts.json comes from `gh` in the workflow: {"ref", "main_sha", "ci_green",
# "labels", "merges"}. This script adds the diff, the
# mix.lock changes, the clock (Europe/Stockholm) and the advisories (hex.pm, the
# data `mix hex.audit` reads, cross-checked with OSV). It writes `ok` and
# `advisories` to $GITHUB_OUTPUT and the rules to $GITHUB_STEP_SUMMARY.
root = Path.expand("../..", __DIR__)
Code.require_file("lib/ex_tales_forge/deploy_lanes.ex", root)
Code.require_file("lib/ex_tales_forge/deploy_lanes/security.ex", root)
Code.require_file("lib/ex_tales_forge/deploy_lanes/security_fix.ex", root)
File.cd!(root)

alias TalesForge.DeployLanes
alias TalesForge.DeployLanes.{Security, SecurityFix}

[stage, base, head, facts_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

git = fn args ->
  {out, 0} = System.cmd("git", args)
  out
end

lock = fn sha ->
  case System.cmd("git", ["show", "#{sha}:mix.lock"], stderr_to_stdout: true) do
    {out, 0} -> out
    _ -> ""
  end
end

{:ok, _} = Application.ensure_all_started([:inets, :ssl])

get = fn url ->
  ssl = [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 4]

  case :httpc.request(
         :get,
         {~c"#{url}", [{~c"user-agent", ~c"tales-forge-security-fix"}]},
         [ssl: ssl, timeout: 20_000],
         body_format: :binary
       ) do
    {:ok, {{_, 200, _}, _, body}} -> {:ok, JSON.decode!(body)}
    _ -> :error
  end
end

changes = Security.lock_changes(lock.(base), lock.(head))

audit =
  for c <- changes, version <- [c.from, c.to], version != nil, into: %{} do
    {{c.package, version}, get.("https://hex.pm/api/packages/#{c.package}/releases/#{version}")}
  end
  |> Enum.flat_map(fn
    {key, {:ok, release}} -> [{key, release["security_advisories"] || []}]
    {_key, :error} -> []
  end)
  |> Map.new()

ids = for {_, advisories} <- audit, %{"id" => id} <- advisories, uniq: true, do: id

osv =
  for id <- ids,
      {:ok, record} <- [get.("https://api.osv.dev/v1/vulns/#{URI.encode(id)}")],
      into: %{},
      do: {id, record}

{clock, 0} = System.cmd("date", ["+%u %H"], env: [{"TZ", "Europe/Stockholm"}])
[day, hour] = clock |> String.split() |> Enum.map(&String.to_integer/1)

# struct!/2, not %Input{}: the module is loaded at run time, after this file compiles.
input =
  struct!(SecurityFix.Input,
    stage: Map.fetch!(%{"merge" => :merge, "deploy" => :deploy}, stage),
    ref: facts["ref"] || "",
    sha: head,
    main_sha: facts["main_sha"] || "",
    clock: {day, hour},
    ci_green: facts["ci_green"] == true,
    lanes: DeployLanes.load(),
    numstat: git.(["diff", "--numstat", "--no-renames", base, head]),
    changes: changes,
    audit: audit,
    osv: osv,
    labels: facts["labels"] || [],
    merges: facts["merges"] || []
  )

result = SecurityFix.check(input)

title =
  "Security-fix guard (#{stage}, #{String.slice(head, 0, 12)}): #{if result.ok, do: "PASS", else: "FAIL"}"

report = Enum.join(["### " <> title | SecurityFix.summary(result)], "\n") <> "\n"
IO.puts(report)

for {var, text} <- [
      {"GITHUB_STEP_SUMMARY", report},
      {"GITHUB_OUTPUT", "ok=#{result.ok}\nadvisories=#{Enum.join(result.advisories, " ")}\n"}
    ],
    path = System.get_env(var),
    path not in [nil, ""],
    do: File.write!(path, text, [:append])
