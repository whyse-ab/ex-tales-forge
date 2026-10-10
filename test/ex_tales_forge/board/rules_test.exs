defmodule TalesForge.Board.RulesTest do
  use ExUnit.Case, async: true

  alias TalesForge.Board.Rules

  doctest TalesForge.Board.Rules
  doctest TalesForge.Board.Ranking

  test "bots and founders get only their moves" do
    assert Rules.targets({:bot, :case}, "ideas") == ["refining"]
    assert Rules.targets({:bot, :case}, "refining") == ["check"]
    assert Rules.targets({:bot, :bobby}, "building") == ["done"]
    assert Rules.targets({:bot, :gentry}, "building") == []
    assert Rules.targets({:founder, "a@x"}, "parked") == ["ideas"]
    assert Rules.actor_name({:bot, :case}) == "bot:case"
  end
end
