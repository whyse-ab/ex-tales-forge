defmodule TalesForge.DeployLanes.SecurityTest do
  use ExUnit.Case, async: true

  alias TalesForge.DeployLanes
  alias TalesForge.DeployLanes.Security
  alias TalesForge.DeployLanes.SecurityCLI
  alias TalesForge.DeployLanes.SecurityAudit

  doctest TalesForge.DeployLanes.Security
  doctest TalesForge.DeployLanes.SecurityCLI

  @dir Path.expand("../fixtures/security_lane", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@dir, name))

  defp input(overrides \\ []) do
    Map.merge(
      %{
        files: ["mix.lock"],
        old_lock: fixture("base.lock"),
        new_lock: fixture("minor.lock"),
        old_mix_exs: fixture("mix_base.exs"),
        new_mix_exs: fixture("mix_base.exs"),
        title: "security: EEF-CVE-2026-97853: decimal 3.1.1 -> 3.2.0",
        body: "",
        labels: ["security"],
        ci_green: true
      },
      Map.new(overrides)
    )
  end

  defp failed(result), do: for(r <- result.rules, not r.ok, do: r.name)

  describe "check/1 qualifies" do
    test "a lock-only minor bump with the label and an advisory id" do
      result = Security.check(input())
      assert result.lane == :security
      assert failed(result) == []

      assert [%{package: "decimal", from: "3.1.1", to: "3.2.0", same_major: true}] =
               result.changes
    end

    test "the title prefix without the label, the advisory id in the body" do
      result =
        Security.check(
          input(labels: [], title: "Security: bump decimal", body: "Fixes GHSA-5chx-gg25-v37m.")
        )

      assert result.lane == :security
    end

    test "a version pin in mix.exs next to the lock" do
      result =
        Security.check(input(files: ["mix.exs", "mix.lock"], new_mix_exs: fixture("mix_pin.exs")))

      assert result.lane == :security
    end

    test "a major bump" do
      result = Security.check(input(new_lock: fixture("major.lock")))
      assert result.lane == :security
      assert failed(result) == []
      assert [%{package: "plug", from: "1.18.0", to: "2.0.0", same_major: false}] = result.changes
    end

    test "a 0.x minor bump (SemVer-major) qualifies like any other bump" do
      result = Security.check(input(new_lock: fixture("zero_minor.lock")))
      assert result.lane == :security
      assert failed(result) == []
    end

    test "a package added to the lock" do
      result = Security.check(input(new_lock: fixture("added.lock")))
      assert result.lane == :security
      assert failed(result) == []
    end
  end

  describe "check/1 falls back to normal" do
    test "extra files" do
      result = Security.check(input(files: ["mix.lock", "lib/ex_tales_forge/game/turn.ex"]))
      assert result.lane == :normal
      assert failed(result) == ["Only mix.lock (and mix.exs pins) change"]
    end

    test "a new dep in mix.exs" do
      result =
        Security.check(
          input(files: ["mix.exs", "mix.lock"], new_mix_exs: fixture("mix_new_dep.exs"))
        )

      assert result.lane == :normal
      assert failed(result) == ["Only mix.lock (and mix.exs pins) change"]
    end

    test "mix.lock does not change" do
      result = Security.check(input(files: ["mix.exs"], new_lock: fixture("base.lock")))
      assert result.lane == :normal
    end

    test "no label and no title prefix" do
      result = Security.check(input(labels: [], title: "Bump decimal (EEF-CVE-2026-97853)"))
      assert result.lane == :normal
      assert failed(result) == ["It references an advisory"]
    end

    test "the label without an advisory id" do
      result = Security.check(input(title: "security: bump decimal", body: "Routine bump."))
      assert result.lane == :normal
      assert failed(result) == ["It references an advisory"]
    end

    test "CI is not green" do
      result = Security.check(input(ci_green: false))
      assert result.lane == :normal
      assert failed(result) == ["CI is green"]
    end
  end

  test "advisory_ids/1 finds CVE, GHSA and EEF-CVE ids" do
    assert Security.advisory_ids("CVE-2025-1234, ghsa-5chx-gg25-v37m and EEF-CVE-2026-97853") ==
             ["CVE-2025-1234", "GHSA-5CHX-GG25-V37M", "EEF-CVE-2026-97853"]
  end

  test "parse_lock/1 reads the repo's own mix.lock" do
    lock = Security.parse_lock(File.read!("mix.lock"))
    assert is_binary(lock["phoenix"])
    assert String.starts_with?(lock["heroicons"], "git:")
  end

  describe "SecurityCLI" do
    # A fake git over two commits: "base" and "head".
    defp git(files, trees) do
      fn
        ["merge-base", "--is-ancestor", _, _] ->
          {"", 0}

        ["merge-base", _, _] ->
          {"base\n", 0}

        ["diff", "--name-only", "--no-renames", _, _] ->
          {Enum.join(files, "\n"), 0}

        ["show", rev_path] ->
          [rev, path] = String.split(rev_path, ":", parts: 2)

          case get_in(trees, [rev, path]) do
            nil -> {"fatal: no such path", 128}
            text -> {text, 0}
          end
      end
    end

    @trees %{
      "base" => %{
        "mix.lock" => File.read!(Path.expand("../fixtures/security_lane/base.lock", __DIR__))
      },
      "head" => %{
        "mix.lock" => File.read!(Path.expand("../fixtures/security_lane/minor.lock", __DIR__))
      }
    }

    @pr %{
      "title" => "security: EEF-CVE-2026-97853",
      "body" => "",
      "labels" => [%{"name" => "security"}]
    }

    test "decide_pr/3: a lock-only minor bump qualifies, the summary lists the rules" do
      result =
        SecurityCLI.decide_pr(
          %SecurityCLI.Run{pr: @pr, ci_green: true, git: git(["mix.lock"], @trees)},
          "main",
          "head"
        )

      assert result.lane == :security
      assert result.advisories == ["EEF-CVE-2026-97853"]
      assert Enum.count(result.summary, &String.starts_with?(&1, "- PASS")) == 3
    end

    test "decide_pr/3: extra files fall back to normal with the reason" do
      result =
        SecurityCLI.decide_pr(
          %SecurityCLI.Run{pr: @pr, ci_green: true, git: git(["mix.lock", "README.md"], @trees)},
          "main",
          "head"
        )

      assert result.lane == :normal
      assert Enum.any?(result.summary, &(&1 =~ "FAIL" and &1 =~ "README.md"))
    end

    test "since_production/3: an unreleased game change keeps production in the normal lane" do
      lanes = DeployLanes.load()
      trees = %{"prod" => @trees["base"], "head" => @trees["head"]}

      ok =
        SecurityCLI.since_production(
          %SecurityCLI.Run{
            lanes: lanes,
            git: git(["mix.lock", "lib/ex_tales_forge_web/live/admin/costs_live.ex"], trees)
          },
          "head",
          "prod"
        )

      assert ok.ok

      bad =
        SecurityCLI.since_production(
          %SecurityCLI.Run{
            lanes: lanes,
            git: git(["mix.lock", "lib/ex_tales_forge/game/turn.ex"], trees)
          },
          "head",
          "prod"
        )

      refute bad.ok
      assert bad.detail =~ "lib/ex_tales_forge/game/turn.ex"

      refute SecurityCLI.since_production(
               %SecurityCLI.Run{lanes: lanes, git: git([], trees)},
               "head",
               nil
             ).ok
    end

    test "extract_json/1 takes the deps.audit report out of mixed output (run 38154907517)" do
      out = fixture("deps_audit_mixed.out")
      assert {:ok, json} = SecurityCLI.extract_json(out)
      assert %{"pass" => false, "vulnerabilities" => [vuln]} = SecurityCLI.decode_pr(json)
      assert vuln["advisory"]["id"] == "GHSA-5chx-gg25-v37m"
    end

    test "extract_json/1: clean JSON as is; compile output alone or a cut-off report is :error" do
      assert SecurityCLI.extract_json(~s({"pass":true,"vulnerabilities":[]})) ==
               {:ok, ~s({"pass":true,"vulnerabilities":[]})}

      assert SecurityCLI.extract_json("==> jido_tools\nwarning: {x}\n") == :error
      assert SecurityCLI.extract_json(~s({"pass":true,"vulnerabilities":[)) == :error
      assert SecurityCLI.extract_json(~s({"pass":true})) == :error
    end

    test "decode_pr/1 reads gh's JSON (escapes, unicode, nesting)" do
      json =
        ~s({"body":"a\\nb \\u00e5 \\ud83d\\ude00","labels":[{"name":"security"}],"n":12,"x":null,"t":true})

      assert SecurityCLI.decode_pr(json) == %{
               "body" => "a\nb å 😀",
               "labels" => [%{"name" => "security"}],
               "n" => 12,
               "x" => nil,
               "t" => true
             }
    end

    test "since_production/3: a major lock bump since production still qualifies" do
      lanes = DeployLanes.load()

      trees = %{
        "prod" => @trees["base"],
        "head" => %{
          "mix.lock" => File.read!(Path.expand("../fixtures/security_lane/major.lock", __DIR__))
        }
      }

      ok =
        SecurityCLI.since_production(
          %SecurityCLI.Run{lanes: lanes, git: git(["mix.lock"], trees)},
          "head",
          "prod"
        )

      assert ok.ok
    end

    test "SecurityAudit.bump/2 accepts a major bump and rejects an unchanged lock" do
      base = fixture("base.lock")
      assert {:ok, desc} = SecurityAudit.bump(base, fixture("major.lock"))
      assert desc =~ "plug 1.18.0 -> 2.0.0"
      assert {:error, "no change"} = SecurityAudit.bump(base, base)
    end
  end

  describe "SecurityAudit.unlock_neighbors/2 and reaches_patched?/3" do
    test "unlocks the package, locked required deps, and locked parents; skips optional deps" do
      lock = fixture("neighbors.lock")

      assert SecurityAudit.unlock_neighbors(lock, "phoenix") == ["phoenix", "phoenix_pubsub"]
      assert SecurityAudit.unlock_neighbors(lock, "phoenix_pubsub") == ["phoenix", "phoenix_pubsub"]
    end

    test "reaches_patched?/3 is inclusive SemVer and ignores missing packages" do
      lock = fixture("major.lock")
      assert SecurityAudit.reaches_patched?(lock, "plug", ["2.0.0"])
      assert SecurityAudit.reaches_patched?(lock, "plug", ["1.18.0", "2.1.0"])
      refute SecurityAudit.reaches_patched?(lock, "plug", ["2.1.0"])
      refute SecurityAudit.reaches_patched?(lock, "missing", ["1.0.0"])
    end
  end
end
