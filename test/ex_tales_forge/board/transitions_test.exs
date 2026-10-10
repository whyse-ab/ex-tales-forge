defmodule TalesForge.Board.TransitionsTest do
  @moduledoc "The card state machine: every row of docs/design-board-states.md is a doctest."
  use ExUnit.Case, async: true

  alias TalesForge.Board.Transitions

  doctest Transitions

  @founder {:founder, "a@x"}
  @actors [@founder, {:bot, :case}, {:bot, :bobby}, {:bot, :gentry}, {:bot, :board}]
  @open %{up: 1, down: 0, refined: true, open_questions: 0, comment: "x", pr_linked: true}

  # The spec's move table: {from, to, actors}.
  @rows [
    {"ideas", "refining", [@founder]},
    {"ideas", "parked", [@founder]},
    {"refining", "check", [{:bot, :case}]},
    {"refining", "ideas", [@founder]},
    {"check", "building", [@founder]},
    {"check", "refining", [@founder]},
    {"check", "parked", [@founder]},
    {"building", "done", [{:bot, :bobby}, {:bot, :board}]},
    {"building", "refining", [{:bot, :bobby}, @founder]},
    {"parked", "ideas", [@founder]}
  ]

  test "exactly the table's moves are possible, for exactly its actors" do
    for from <- Transitions.states(), to <- Transitions.states(), actor <- @actors do
      ok? =
        Enum.any?([:awaiting, :approved, nil], fn pr ->
          Transitions.allowed?(Map.put(@open, :pr, pr), from, to, actor) == :ok
        end)

      expected? = Enum.any?(@rows, fn {f, t, who} -> f == from and t == to and actor in who end)
      assert ok? == expected?, "#{from} → #{to} for #{inspect(actor)}"
    end
  end
end
