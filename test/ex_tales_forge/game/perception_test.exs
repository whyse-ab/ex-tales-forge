defmodule TalesForge.Game.PerceptionTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.Context
  alias TalesForge.Game.Perception
  alias TalesForge.GameSessions
  alias TalesForge.Jido

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  test "Crossroads GM prompt keeps Marta focus and stock, drops initiative internals" do
    {:ok, session} = GameSessions.create_session(%{name: "Perception Crossroads"})
    prompt = Context.format_gm_prompt(Context.build_gm_context(session))

    assert prompt =~ "Marta"
    assert prompt =~ "missing ledger"
    assert prompt =~ "ale" or prompt =~ "Mug of Ale"
    refute prompt =~ "initiative_emitted"
    refute prompt =~ "concern_wait_ticks"
    refute prompt =~ "runtime_state"
  end

  test "ordinary looks keep alert/prepared/scout in situation lines" do
    world = %{
      "situation_lines" => [
        "Brenna looks alert behind the bar.",
        "The square is prepared for market day.",
        "A guild scout waits by the well."
      ]
    }

    scrubbed = Perception.scrub_situation_lines(world, [])
    assert scrubbed["situation_lines"] == world["situation_lines"]
  end

  test "hidden scout events still strip alert/prepared/scout situation lines" do
    world = %{
      "situation_lines" => [
        "The nest is prepared and on alert; scouts out.",
        "You have just pushed through the inn door."
      ]
    }

    hidden = [
      %{
        "kind" => "player.failed_notice",
        "payload" => %{"what" => "approached from the west road; scouts unseen"}
      }
    ]

    scrubbed = Perception.scrub_situation_lines(world, hidden)
    assert scrubbed["situation_lines"] == ["You have just pushed through the inn door."]
  end
end
