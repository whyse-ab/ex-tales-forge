defmodule TalesForge.DeployLanesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Deploy.CheckBoundaries
  alias TalesForge.DeployLanes
  alias TalesForge.DeployLanes.CLI

  doctest TalesForge.DeployLanes

  @lanes DeployLanes.load()

  # Files changed by real merges to main (gh pr view <n> --json files).
  @merges %{
    106 => [
      "lib/ex_tales_forge_web/components/team_art.ex",
      "lib/ex_tales_forge_web/components/team_components.ex",
      "lib/ex_tales_forge_web/live/team_live.ex",
      "lib/ex_tales_forge_web/live/team_presentation_live.ex",
      "priv/team/data.json",
      "test/ex_tales_forge_web/live/team_live_test.exs",
      "test/ex_tales_forge_web/live/team_presentation_live_test.exs"
    ],
    105 => [
      "assets/css/app.css",
      "assets/js/app.js",
      "assets/js/team_hooks.js",
      "lib/ex_tales_forge/team_page.ex",
      "lib/ex_tales_forge_web/components/team_art.ex",
      "lib/ex_tales_forge_web/components/team_board.ex",
      "lib/ex_tales_forge_web/components/team_call_types.ex",
      "lib/ex_tales_forge_web/components/team_components.ex",
      "lib/ex_tales_forge_web/components/team_layout.ex",
      "lib/ex_tales_forge_web/live/team_live.ex",
      "lib/ex_tales_forge_web/live/team_presentation_live.ex",
      "lib/ex_tales_forge_web/router.ex",
      "priv/team/README.md",
      "priv/team/data.json",
      "test/ex_tales_forge_web/live/team_live_test.exs",
      "test/ex_tales_forge_web/live/team_presentation_live_test.exs"
    ],
    104 => [
      "AGENTS.md",
      "lib/ex_tales_forge/game/context.ex",
      "lib/ex_tales_forge/game/progression.ex",
      "lib/ex_tales_forge/game/turn_processor.ex",
      "priv/adventures/crossroads_ledger/rules/combat.md",
      "priv/adventures/crossroads_ledger/rules/core_mechanics.md",
      "priv/adventures/crossroads_ledger/rules/skills.md",
      "priv/adventures/tin_valley/rules/combat.md",
      "priv/adventures/tin_valley/rules/core_mechanics.md",
      "priv/adventures/tin_valley/rules/skills.md",
      "priv/rules/combat.md",
      "priv/rules/core_mechanics.md",
      "priv/rules/skills.md",
      "test/ex_tales_forge/game/competence_test.exs",
      "test/ex_tales_forge/game/rest_growth_test.exs",
      "test/fixtures/prompts/crossroads_ledger.txt",
      "test/fixtures/prompts/gm_turn/crossroads_ledger.txt",
      "test/fixtures/prompts/gm_turn/tin_valley.txt",
      "test/fixtures/prompts/tin_valley.txt"
    ],
    99 => [
      "lib/ex_tales_forge_web/components/team_art.ex",
      "priv/static/images/team/hero-1280.jpg",
      "priv/static/images/team/hero-1280.webp",
      "priv/static/images/team/hero-480.jpg",
      "priv/static/images/team/hero-480.webp",
      "priv/static/images/team/hero-960.jpg",
      "priv/static/images/team/hero-960.webp",
      "test/ex_tales_forge_web/live/team_live_test.exs"
    ],
    97 => [
      ".github/workflows/playtest.yml",
      "AGENTS.md",
      "docs/DEPLOY-FLY.md"
    ]
  }

  describe "the real list (.github/deploy-lanes.txt)" do
    test "admin-only merges take the admin lane: #106 (/team copy and data), #99 (/team hero)" do
      for pr <- [106, 99] do
        assert %{lane: :admin, other: []} = DeployLanes.classify(@lanes, @merges[pr]), "##{pr}"
      end
    end

    test "#104 (game: progression, turn processor, rules, prompt fixtures) takes the normal lane" do
      result = DeployLanes.classify(@lanes, @merges[104])
      assert result.lane == :normal
      assert "lib/ex_tales_forge/game/progression.ex" in result.other
      assert "priv/rules/skills.md" in result.other
    end

    test "#105 is normal: besides /team files it changed the router and the shared CSS and JS bundle" do
      result = DeployLanes.classify(@lanes, @merges[105])
      assert result.lane == :normal

      assert result.other == [
               "assets/css/app.css",
               "assets/js/app.js",
               "lib/ex_tales_forge_web/router.ex"
             ]
    end

    test "#97 (CI workflow) is normal" do
      assert DeployLanes.classify(@lanes, @merges[97]).lane == :normal
    end

    test "a mixed merge counts as a game change" do
      assert DeployLanes.classify(@lanes, [
               "priv/team/data.json",
               "lib/ex_tales_forge/game/intent.ex"
             ]).lane ==
               :normal
    end

    test "shared files are never admin" do
      for file <- [
            "lib/ex_tales_forge/admin_auth.ex",
            "lib/ex_tales_forge/repo.ex",
            "priv/repo/migrations/20261009000000_add.exs",
            "config/runtime.exs",
            "lib/ex_tales_forge/ai_calls.ex",
            "mix.exs",
            "mix.lock",
            ".github/workflows/ci.yml",
            ".github/deploy-lanes.txt",
            ".credo.exs",
            "lib/ex_tales_forge/deploy_lanes.ex",
            "lib/ex_tales_forge_web/router.ex",
            "lib/ex_tales_forge_web/controllers/costs_peer_controller.ex",
            "lib/ex_tales_forge/playtest/runner.ex",
            "priv/adventures/tin_valley/pack.yaml",
            "priv/npcs/brenna.md",
            "Dockerfile"
          ] do
        refute DeployLanes.admin?(@lanes, file), file
      end
    end

    test "no file is both admin and game" do
      both =
        for path <- tracked_files(),
            DeployLanes.admin?(@lanes, path),
            DeployLanes.matches?(@lanes.game, path),
            do: path

      assert both == []
    end

    test "an empty or unknown change set is normal" do
      assert DeployLanes.classify(@lanes, []).lane == :normal
      assert DeployLanes.classify(@lanes, ["something/new.txt"]).lane == :normal
    end
  end

  describe "parse/1 and compile/1" do
    test "directories, globs and exact paths" do
      lanes = DeployLanes.parse("[admin]\na/dir/\nb/team_*.ex\nc/**/x.json\nd.ex # comment\n")
      assert DeployLanes.admin?(lanes, "a/dir/deep/file.ex")
      refute DeployLanes.admin?(lanes, "a/directory.ex")
      assert DeployLanes.admin?(lanes, "b/team_art.ex")
      refute DeployLanes.admin?(lanes, "b/sub/team_art.ex")
      assert DeployLanes.admin?(lanes, "c/one/two/x.json")
      assert DeployLanes.admin?(lanes, "d.ex")
      refute DeployLanes.admin?(lanes, "d.exs")
      refute DeployLanes.admin?(lanes, "xd.ex")
    end

    test "dots and other regex characters are literal" do
      lanes = DeployLanes.parse("[admin]\nlib/a.ex\n")
      refute DeployLanes.admin?(lanes, "lib/aXex")
    end

    test "malformed files raise" do
      assert_raise ArgumentError, ~r/unknown section/, fn -> DeployLanes.parse("[fast]\na\n") end

      assert_raise ArgumentError, ~r/not under a \[section\]/, fn ->
        DeployLanes.parse("a\n[admin]\nb\n")
      end

      assert_raise ArgumentError, ~r/empty/, fn -> DeployLanes.parse("[game]\na\n") end
    end

    test "unused_patterns/3 lists patterns that match no file" do
      lanes = DeployLanes.parse("[admin]\na/\nb.ex\n")
      assert DeployLanes.unused_patterns(lanes, :admin, ["a/x.ex"]) == ["b.ex"]
    end
  end

  describe "boundary_violations/2" do
    @boundary DeployLanes.parse("""
              [admin]
              lib/admin/
              [game]
              lib/game/
              [wiring]
              lib/router.ex
              """)

    test "game and shared files may not depend on admin files; wiring and admin may" do
      edges = [
        {"lib/game/turn.ex", "lib/admin/costs.ex"},
        {"lib/shared/role.ex", "lib/admin/costs.ex"},
        {"lib/router.ex", "lib/admin/costs_live.ex"},
        {"lib/admin/costs.ex", "lib/game/turn.ex"},
        {"lib/admin/costs_live.ex", "lib/admin/costs.ex"},
        {"lib/game/turn.ex", "lib/shared/role.ex"}
      ]

      assert DeployLanes.boundary_violations(@boundary, edges) == [
               %{kind: :game, from: "lib/game/turn.ex", to: "lib/admin/costs.ex"},
               %{kind: :shared, from: "lib/shared/role.ex", to: "lib/admin/costs.ex"}
             ]
    end

    test "parse_xref_dot/1 reads the file-level edges of `mix xref graph --format dot`" do
      dot = """
      digraph "xref graph" {
        "lib/a.ex"
        "lib/a.ex" -> "lib/b.ex" [label="(compile)"]
        "lib/b.ex" -> "lib/c.ex"
        "lib/b.ex" -> "lib/c.ex"
      }
      """

      assert DeployLanes.parse_xref_dot(dot) == [
               {"lib/a.ex", "lib/b.ex"},
               {"lib/b.ex", "lib/c.ex"}
             ]
    end

    test "the failure message names each edge and the fix" do
      message =
        CheckBoundaries.failure_message(
          ".github/deploy-lanes.txt",
          [%{kind: :game, from: "lib/game/turn.ex", to: "lib/admin/costs.ex"}],
          ["[admin] lib/gone.ex"]
        )

      assert message =~
               "lib/game/turn.ex -> lib/admin/costs.ex  (game code depends on admin code)"

      assert message =~ "Move the shared part out of the admin file"
      assert message =~ "[admin] lib/gone.ex matches no file in the repo"
    end
  end

  describe "CLI.decide/4" do
    @cli_lanes DeployLanes.parse("[admin]\npriv/team/\n")

    # A fake git: diffs by range, and which commits are ancestors of the merge.
    defp fake_git(diffs, ancestors \\ ["prod"]) do
      fn
        ["diff", "--name-only", "--no-renames", from, to] ->
          {Enum.join(Map.fetch!(diffs, {from, to}), "\n"), 0}

        ["merge-base", "--is-ancestor", base, _sha] ->
          {"", if(base in ancestors, do: 0, else: 1)}
      end
    end

    test "admin when the merge and everything since production are admin-only" do
      git =
        fake_git(%{
          {"m^1", "m"} => ["priv/team/data.json"],
          {"prod", "m"} => ["priv/team/data.json"]
        })

      assert %{lane: :admin, summary: [heading | _]} = CLI.decide(@cli_lanes, "m", "prod", git)
      assert heading =~ "admin (fast lane)"
    end

    test "normal when production still waits for an earlier game merge" do
      git =
        fake_git(%{
          {"m^1", "m"} => ["priv/team/data.json"],
          {"prod", "m"} => ["priv/team/data.json", "lib/ex_tales_forge/game/progression.ex"]
        })

      result = CLI.decide(@cli_lanes, "m", "prod", git)
      assert result.lane == :normal
      assert Enum.join(result.summary, "\n") =~ "lib/ex_tales_forge/game/progression.ex"
      assert Enum.join(result.summary, "\n") =~ "gh workflow run deploy-production.yml -f sha=m"
    end

    test "normal when production's commit is unknown or not an ancestor" do
      git = fake_git(%{{"m^1", "m"} => ["priv/team/data.json"]})
      assert %{lane: :normal, summary: summary} = CLI.decide(@cli_lanes, "m", nil, git)
      assert Enum.join(summary, "\n") =~ "no `deployed/production` tag"
      assert CLI.decide(@cli_lanes, "m", "elsewhere", git).lane == :normal
      assert CLI.decide(@cli_lanes, "m", "m", git).lane == :normal
    end

    test "normal for a game merge" do
      git = fake_git(%{{"m^1", "m"} => ["lib/game.ex"], {"prod", "m"} => ["lib/game.ex"]})
      assert CLI.decide(@cli_lanes, "m", "prod", git).lane == :normal
    end

    test "decide_files/2 classifies a plain list" do
      assert CLI.decide_files(@cli_lanes, ["priv/team/a.json"]).lane == :admin
      assert CLI.decide_files(@cli_lanes, ["priv/team/a.json", "mix.exs"]).lane == :normal
    end
  end

  defp tracked_files do
    {out, 0} = System.cmd("git", ["ls-files"])
    String.split(out, "\n", trim: true)
  end
end
