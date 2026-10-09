defmodule TalesForge.TeamPageTest do
  use ExUnit.Case, async: true

  alias TalesForge.TeamPage

  doctest TalesForge.TeamPage

  test "the bundled data is priv/team/data.json, decoded" do
    assert TeamPage.data() == TeamPage.data_path() |> File.read!() |> Jason.decode!()
    assert TeamPage.data_path() |> String.ends_with?("priv/team/data.json")
  end

  test "the data has what the page reads" do
    data = TeamPage.data()

    for path <- [
          ["_about", "as_of"],
          ["team", "members"],
          ["change_flow", "steps"],
          ["decisions", "by_date"],
          ["pace", "prs_by_day"],
          ["playtest_series", "series"],
          ["intent_shadow", "p95_ms"],
          ["ai_spend", "documented_items_usd"]
        ] do
      assert TeamPage.get(data, path) != nil, "data.json has no #{Enum.join(path, ".")}"
    end
  end

  describe "the call-type walkthrough's data" do
    test "the new call_types keys are there" do
      data = TeamPage.data()

      for kind <- ~w(jev elixir llm), key <- ~w(css_var light dark name) do
        assert TeamPage.get(data, ["call_types", "colours", kind, key]) != nil,
               "data.json has no call_types.colours.#{kind}.#{key}"
      end

      for path <- [
            ["call_types", "why", "elixir"],
            ["call_types", "why", "jev"],
            ["call_types", "why", "llm"],
            ["call_types", "smell"],
            ["call_types", "walkthrough", "player_text"],
            ["call_types", "walkthrough", "steps"],
            ["call_types", "examples", "elixir"],
            ["call_types", "examples", "jev"],
            ["call_types", "examples", "llm"],
            ["intent_shadow", "cost_per_turn_usd"]
          ] do
        assert TeamPage.get(data, path) != nil, "data.json has no #{Enum.join(path, ".")}"
      end
    end

    test "one step per lane, Jev then Elixir then the GM, each with a label and detail" do
      steps = TeamPage.get(TeamPage.data(), ["call_types", "walkthrough", "steps"])

      assert Enum.map(steps, & &1["lane"]) == ["jev", "elixir", "llm"]

      for step <- steps do
        assert is_binary(step["label"]) and step["label"] != ""
        assert is_map(step["detail"]) and map_size(step["detail"]) > 0
      end

      [jev | _] = steps
      assert TeamPage.get(TeamPage.data(), String.split(jev["latency_ref"], ".")) |> is_number()
    end

    test "the colours are the page's CSS variables, light and dark, as in app.css" do
      css = File.read!("assets/css/app.css")
      [_, light] = Regex.run(~r/\n\.team-page \{([^}]*)\}/, css)
      [_, dark] = Regex.run(~r/:root\[data-theme="dark"\] \.team-page \{([^}]*)\}/, css)

      for {kind, colour} <- TeamPage.get(TeamPage.data(), ["call_types", "colours"]),
          kind in ~w(jev elixir llm) do
        assert colour["css_var"] == "--team-#{kind}"
        assert light =~ "#{colour["css_var"]}: #{colour["light"]};", "#{kind} light"
        assert dark =~ "#{colour["css_var"]}: #{colour["dark"]};", "#{kind} dark"
      end
    end

    test "the walkthrough's roll is what Game.Mechanics would do" do
      steps = TeamPage.get(TeamPage.data(), ["call_types", "walkthrough", "steps"])
      jev = Enum.find(steps, &(&1["lane"] == "jev"))["detail"]
      elixir = Enum.find(steps, &(&1["lane"] == "elixir"))["detail"]
      [stat, value] = String.split(elixir["stat"])
      value = String.to_integer(value)

      assert TalesForge.Game.Mechanics.skill_stat_map()[jev["skill"]] == stat
      assert elixir["stat_bonus"] == div(value - 10, 2)
      assert elixir["target"] == elixir["skill_level"] + elixir["stat_bonus"]

      character = %{
        "skills" => %{jev["skill"] => elixir["skill_level"]},
        "stats" => %{stat => value}
      }

      {_character, resolution} =
        TalesForge.Game.Mechanics.perform_and_apply(character, jev["skill"], elixir["die"])

      assert resolution.effective_skill == elixir["target"]
      assert resolution.outcome == elixir["outcome"]
    end
  end

  test "the change flow goes to playtest before production, through two founder approvals" do
    ids = TeamPage.data() |> TeamPage.get(["change_flow", "steps"]) |> Enum.map(& &1["id"])
    index = &Enum.find_index(ids, fn id -> id == &1 end)

    assert index.("playtest") < index.("check")
    assert index.("check") < index.("ok_prod")
    assert index.("ok_prod") < index.("prod")

    approvals =
      TeamPage.data() |> TeamPage.get(["change_flow", "steps"]) |> Enum.filter(& &1["approval"])

    assert Enum.map(approvals, & &1["id"]) == ["ok_merge", "ok_prod"]
  end

  describe "missing values read 'not measured yet', never zero" do
    test "every formatter" do
      for value <- [nil, "", %{}, [], :none] do
        assert TeamPage.number(value) == "not measured yet"
        assert TeamPage.usd(value) == "not measured yet"
        assert TeamPage.pct(value) == "not measured yet"
        assert TeamPage.ms(value) == "not measured yet"
        assert TeamPage.score(value) == "not measured yet"
        assert TeamPage.date_label(value) == "not measured yet"
      end
    end

    test "but a measured zero is a zero" do
      assert TeamPage.number(0) == "0"
      assert TeamPage.measured?(0)
      refute TeamPage.measured?(nil)
      refute TeamPage.measured?("  ")
    end
  end

  test "number formatting" do
    assert TeamPage.number(1_234_567) == "1,234,567"
    assert TeamPage.number(-1234) == "-1,234"
    assert TeamPage.number(14.0) == "14"
    assert TeamPage.usd(14.0) == "$14.00"
    assert TeamPage.usd(0.016) == "$0.016"
    assert TeamPage.share(150, 100) == 100.0
    assert TeamPage.share(5, 0) == 0.0
  end
end
