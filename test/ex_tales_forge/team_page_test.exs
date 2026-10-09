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
