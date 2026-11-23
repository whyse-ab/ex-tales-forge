defmodule TalesForge.DeployLanes.SecurityFix do
  @moduledoc """
  The **security-fix** lane (`docs/environments.md`, "Off-hours security fixes";
  Fredrik, 2026-10-27 and 2026-11-23): outside working hours a bot may merge a
  pull request that fixes a high or critical dependency advisory. After the
  playtest smoke check succeeds, the deploy proceeds without a founder's
  approval, at any hour, through the `production-security` environment. A flaw
  in our own code gets containment only, never this lane.

  `check/1` is the guard. It runs twice, each time from `main`'s copy of this
  module (never the pull request's): before the merge (`stage: :merge`,
  `security-lane.yml`) and again right before the deploy (`stage: :deploy`,
  `security-fix-deploy.yml`), where the diff is production's sha against the
  sha to ship. Every rule must pass:

    1. **Main only.** The run is on `refs/heads/main`; a deploy ships the tip
       of `main`.
    2. **Merge only: outside working hours.** Not Mon-Fri 08:00-18:00
       Europe/Stockholm. A deploy may run at any hour (Fredrik, 2026-11-23).
    3. **CI green** (Test and Dialyzer) on the exact sha.
    4. **Size cap.** At most 10 files and 300 changed lines.
    5. **No founder paths** from `.github/deploy-lanes.txt`, except `mix.exs`
       and `mix.lock`.
    6. **Advisory.** A package that changes in `mix.lock` has a hex.pm advisory
       at its base version, rated high or critical, that is gone at its head
       version, and whose OSV record names that Hex package with the same CVSS
       vector and is not withdrawn. An unknown head audit is not clean.
    7. Merge: the label `security-fix`. Deploy: every merge since production
       is a `security-fix` pull request.

  The defaults of `Input` fail every rule. Standard library only, so the
  workflows load it with plain `elixir` (`.github/scripts/security_fix.exs`).

      iex> TalesForge.DeployLanes.SecurityFix.working_hours?({5, 17})
      true
      iex> TalesForge.DeployLanes.SecurityFix.working_hours?({6, 12})
      false
  """

  alias TalesForge.DeployLanes

  @max_files 10
  @max_lines 300
  @label "security-fix"
  @allowed ["mix.exs", "mix.lock"]

  defmodule Input do
    @moduledoc "What the edge gathered for `TalesForge.DeployLanes.SecurityFix.check/1`."

    @typedoc """
    `clock` is `{iso_weekday, hour}` in Europe/Stockholm. `audit` maps
    `{package, version}` to hex.pm's `security_advisories`; `osv` maps an
    advisory id to its OSV record. `merges` holds `%{"sha", "labels"}` per
    merge since production.
    """
    @type t :: %__MODULE__{
            stage: :merge | :deploy,
            ref: String.t(),
            sha: String.t(),
            main_sha: String.t(),
            clock: {1..7, 0..23},
            ci_green: boolean(),
            lanes: DeployLanes.t() | nil,
            numstat: String.t(),
            changes: [map()],
            audit: %{{String.t(), String.t()} => [map()]},
            osv: %{String.t() => map()},
            labels: [String.t()],
            merges: [map()]
          }
    defstruct stage: :deploy,
              ref: "",
              sha: "",
              main_sha: "",
              clock: {1, 12},
              ci_green: false,
              lanes: nil,
              numstat: "",
              changes: [],
              audit: %{},
              osv: %{},
              labels: [],
              merges: []
  end

  @type rule :: %{name: String.t(), ok: boolean(), detail: String.t()}
  @type result :: %{ok: boolean(), rules: [rule()], advisories: [String.t()]}

  @doc "Checks every rule; `ok` only when all pass."
  @spec check(Input.t()) :: result()
  def check(%Input{} = input) do
    ids = fixed_advisories(input)
    files = parse_numstat(input.numstat)

    rules =
      [
        main_rule(input),
        rule("CI green on the sha", input.ci_green, ci_detail(input.ci_green)),
        size_rule(files),
        founder_rule(input.lanes, files),
        rule(
          "A high or critical OSV advisory on base is gone on head",
          ids != [],
          list(ids)
        )
      ] ++ stage_rules(input)

    %{ok: Enum.all?(rules, & &1.ok), rules: rules, advisories: ids}
  end

  @doc "Mon-Fri 08:00-17:59 (`{iso_weekday, hour}`)."
  @spec working_hours?({integer(), integer()}) :: boolean()
  def working_hours?({day, hour}), do: day in 1..5 and hour in 8..17

  @doc "One Markdown line per rule."
  @spec summary(result()) :: [String.t()]
  def summary(%{rules: rules}) do
    for r <- rules, do: "- #{if r.ok, do: "PASS", else: "FAIL"} #{r.name}: #{r.detail}"
  end

  defp main_rule(%Input{stage: :merge, ref: ref}),
    do: rule("Main only", ref == "refs/heads/main", ref)

  defp main_rule(%Input{ref: ref, sha: sha, main_sha: main}) do
    ok = ref == "refs/heads/main" and sha != "" and sha == main
    rule("Main only", ok, "#{ref}, #{sha} (tip of main #{main})")
  end

  defp stage_rules(%Input{stage: :merge, labels: labels, clock: clock}) do
    [
      rule("Outside working hours", not working_hours?(clock), "#{inspect(clock)}"),
      rule("Label #{@label}", @label in labels, list(labels))
    ]
  end

  defp stage_rules(input) do
    shas = for m <- input.merges, @label not in m["labels"], do: m["sha"]

    [
      rule(
        "Only #{@label} merges since production",
        input.merges != [] and shas == [],
        "not #{@label}: #{list(shas)}"
      )
    ]
  end

  defp ci_detail(true), do: "Test and Dialyzer passed."
  defp ci_detail(false), do: "Test or Dialyzer did not pass."

  defp size_rule(files) do
    lines = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    ok = files != [] and length(files) <= @max_files and lines <= @max_lines

    rule(
      "At most #{@max_files} files and #{@max_lines} lines",
      ok,
      "#{length(files)} files, #{lines} lines"
    )
  end

  defp founder_rule(nil, _files),
    do: rule("No founder paths", false, "deploy-lanes.txt not loaded")

  defp founder_rule(lanes, files) do
    bad =
      for {path, _} <- files, path not in @allowed, DeployLanes.founder?(lanes, path), do: path

    rule("No founder paths", bad == [], list(bad))
  end

  defp parse_numstat(numstat) do
    for line <- String.split(numstat, "\n", trim: true),
        [added, deleted, path] <- [String.split(line, "\t", parts: 3)],
        do: {path, count(added) + count(deleted)}
  end

  defp count("-"), do: 0
  defp count(n), do: String.to_integer(n)

  defp fixed_advisories(%Input{changes: changes} = input),
    do: changes |> Enum.flat_map(&fixed_by(input, &1)) |> Enum.uniq()

  defp fixed_by(%Input{audit: audit, osv: osv}, change) do
    case head_audit(audit, change) do
      {:ok, head} ->
        gone = Enum.map(head, & &1["id"])

        for advisory <- Map.get(audit, {change.package, change.from}, []),
            advisory["id"] not in gone,
            qualifies?(advisory, osv[advisory["id"]], change.package),
            do: advisory["id"]

      :error ->
        []
    end
  end

  defp qualifies?(advisory, record, package),
    do: severe?(advisory) and osv_confirms?(record, package, advisory["cvss_vector"])

  defp head_audit(_audit, %{to: nil}), do: {:ok, []}
  defp head_audit(audit, change), do: Map.fetch(audit, {change.package, change.to})

  defp severe?(advisory),
    do: advisory["withdrawn_at"] == nil and advisory["cvss_rating"] in ["high", "critical"]

  defp osv_confirms?(%{"affected" => affected} = record, package, vector) do
    names = for %{"package" => %{"ecosystem" => "Hex", "name" => name}} <- affected, do: name
    vectors = for %{"score" => score} <- record["severity"] || [], do: score
    record["withdrawn"] == nil and package in names and vector in vectors
  end

  defp osv_confirms?(_record, _package, _vector), do: false

  defp list([]), do: "none"
  defp list(items), do: Enum.join(items, ", ")

  defp rule(name, ok, detail), do: %{name: name, ok: ok, detail: detail}
end
