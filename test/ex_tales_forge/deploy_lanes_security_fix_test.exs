defmodule TalesForge.DeployLanes.SecurityFixTest do
  use ExUnit.Case, async: true

  alias TalesForge.DeployLanes
  alias TalesForge.DeployLanes.SecurityFix
  alias TalesForge.DeployLanes.SecurityFix.Input

  doctest SecurityFix

  @sha String.duplicate("a", 40)
  @vector "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:H/SC:N/SI:N/SA:N"
  @lanes DeployLanes.load()

  defp advisory(id, rating),
    do: %{"id" => id, "cvss_rating" => rating, "cvss_vector" => @vector, "withdrawn_at" => nil}

  defp osv(id, package) do
    %{
      "id" => id,
      "affected" => [%{"package" => %{"ecosystem" => "Hex", "name" => package}}],
      "severity" => [%{"type" => "CVSS_V4", "score" => @vector}]
    }
  end

  # A night-time deploy of a bandit bump that clears one high advisory.
  defp input(overrides \\ []) do
    struct!(
      %Input{
        stage: :deploy,
        ref: "refs/heads/main",
        sha: @sha,
        main_sha: @sha,
        clock: {2, 23},
        ci_green: true,
        lanes: @lanes,
        numstat: "1\t1\tmix.lock\n12\t3\tlib/ex_tales_forge_web/endpoint.ex\n",
        changes: [%{package: "bandit", from: "1.13.0", to: "1.14.0", same_major: true}],
        audit: %{
          {"bandit", "1.13.0"} => [advisory("EEF-CVE-2026-1", "high")],
          {"bandit", "1.14.0"} => []
        },
        osv: %{"EEF-CVE-2026-1" => osv("EEF-CVE-2026-1", "bandit")},
        merges: [%{"sha" => @sha, "labels" => ["security-fix"]}]
      },
      overrides
    )
  end

  defp failed(input), do: for(r <- SecurityFix.check(input).rules, not r.ok, do: r.name)

  describe "a deploy" do
    test "qualifies when every rule passes, and names the fixed advisory" do
      result = SecurityFix.check(input())
      assert result.ok
      assert result.advisories == ["EEF-CVE-2026-1"]
      assert failed(input()) == []
    end

    test "fails closed with the struct defaults" do
      result = SecurityFix.check(%Input{})
      refute result.ok
      assert length(result.rules) == 6
    end

    test "needs main: the run's ref and the tip of main" do
      assert failed(input(ref: "refs/heads/bobby/x")) == ["Main only"]
      assert failed(input(main_sha: String.duplicate("b", 40))) == ["Main only"]
    end

    test "may run during Mon-Fri 08:00-18:00 Stockholm" do
      for clock <- [{1, 8}, {3, 12}, {5, 17}] do
        assert failed(input(clock: clock)) == []
      end
    end

    test "needs CI green on the exact sha" do
      assert failed(input(ci_green: false)) == ["CI green on the sha"]
    end

    test "ships nothing but security-fix merges since production" do
      assert failed(input(merges: [])) == ["Only security-fix merges since production"]

      other = %{"sha" => String.duplicate("c", 40), "labels" => []}

      assert failed(input(merges: [other | input().merges])) ==
               ["Only security-fix merges since production"]
    end
  end

  describe "the size cap and founder paths" do
    test "at most 10 files" do
      numstat = Enum.map_join(1..11, "", &"1\t0\tlib/f#{&1}.ex\n") <> "1\t1\tmix.lock\n"
      assert failed(input(numstat: numstat)) == ["At most 10 files and 300 lines"]
    end

    test "at most 300 changed lines, a binary file counting as one file" do
      assert failed(input(numstat: "1\t1\tmix.lock\n200\t99\tlib/a.ex\n")) ==
               ["At most 10 files and 300 lines"]

      assert failed(input(numstat: "1\t1\tmix.lock\n-\t-\tpriv/static/x.png\n")) ==
               ["No founder paths"]
    end

    test "mix.exs and mix.lock are allowed; .github/, config/ and SQL are not" do
      assert failed(input(numstat: "1\t1\tmix.lock\n1\t1\tmix.exs\n")) == []

      for path <- [".github/workflows/ci.yml", "config/runtime.exs", "lib/x.sql"] do
        assert failed(input(numstat: "1\t1\tmix.lock\n1\t0\t#{path}\n")) == ["No founder paths"]
      end
    end
  end

  describe "the advisory (base against head audit)" do
    @rule "A high or critical OSV advisory on base is gone on head"

    test "needs the advisory on the base version and not on the head version" do
      still = %{
        {"bandit", "1.13.0"} => [advisory("EEF-CVE-2026-1", "high")],
        {"bandit", "1.14.0"} => [advisory("EEF-CVE-2026-1", "high")]
      }

      assert failed(input(audit: still)) == [@rule]

      assert failed(input(audit: %{{"bandit", "1.13.0"} => [], {"bandit", "1.14.0"} => []})) == [
               @rule
             ]
    end

    test "an unknown head audit does not count as clean" do
      assert failed(input(audit: %{{"bandit", "1.13.0"} => [advisory("EEF-CVE-2026-1", "high")]})) ==
               [@rule]
    end

    test "a removed package clears its advisories" do
      changes = [%{package: "bandit", from: "1.13.0", to: nil, same_major: false}]
      assert failed(input(changes: changes)) == []
    end

    test "high or critical only" do
      for rating <- ["medium", "low", nil] do
        audit = %{
          {"bandit", "1.13.0"} => [advisory("EEF-CVE-2026-1", rating)],
          {"bandit", "1.14.0"} => []
        }

        assert failed(input(audit: audit)) == [@rule]
      end

      audit = %{
        {"bandit", "1.13.0"} => [advisory("EEF-CVE-2026-1", "critical")],
        {"bandit", "1.14.0"} => []
      }

      assert failed(input(audit: audit)) == []
    end

    test "the OSV record must exist, name the changed Hex package and carry the same CVSS vector" do
      assert failed(input(osv: %{})) == [@rule]
      assert failed(input(osv: %{"EEF-CVE-2026-1" => osv("EEF-CVE-2026-1", "plug")})) == [@rule]

      other_vector =
        put_in(osv("EEF-CVE-2026-1", "bandit"), ["severity"], [%{"score" => "CVSS:4.0/x"}])

      assert failed(input(osv: %{"EEF-CVE-2026-1" => other_vector})) == [@rule]

      withdrawn = Map.put(osv("EEF-CVE-2026-1", "bandit"), "withdrawn", "2026-10-27T00:00:00Z")
      assert failed(input(osv: %{"EEF-CVE-2026-1" => withdrawn})) == [@rule]
    end

    test "a change without a lock change (a fix in our own code) never qualifies" do
      assert failed(input(changes: [], numstat: "3\t1\tlib/a.ex\n")) == [@rule]
    end
  end

  describe "a pull request (stage :merge)" do
    defp pr(overrides),
      do: input(Keyword.merge([stage: :merge, labels: ["security-fix"], merges: []], overrides))

    test "qualifies without the tip of main" do
      assert SecurityFix.check(pr(main_sha: "")).ok
    end

    test "needs the label security-fix and the night" do
      assert failed(pr(labels: ["security"])) == ["Label security-fix"]
      assert failed(pr(clock: {2, 10})) == ["Outside working hours"]

      for clock <- [{1, 7}, {5, 18}, {6, 12}, {7, 9}] do
        assert failed(pr(clock: clock)) == []
      end
    end
  end

  test "summary/1 lists every rule with PASS or FAIL" do
    lines = input(ci_green: false) |> SecurityFix.check() |> SecurityFix.summary()
    assert "- FAIL CI green on the sha: Test or Dialyzer did not pass." in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "- PASS Main only"))
  end
end
