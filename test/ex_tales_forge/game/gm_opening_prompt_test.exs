defmodule TalesForge.Game.GMOpeningPromptTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.Context
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.Scene

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  test "GM turn prompt includes the opening scene, clearly labelled" do
    {:ok, session} = GameSessions.create_session(%{name: "GM Opening Prompt"})

    opening =
      GameSessions.opening_scene(session.id) ||
        Repo.insert!(%Scene{
          game_session_id: session.id,
          location_id: "weary_pilgrim",
          location_name: "The Weary Pilgrim",
          narrative: "Smoke curls under the low beams as you push through the door."
        })

    # Make the narrative distinctive so we know the prompt carried this row.
    {:ok, opening} =
      opening
      |> Ecto.Changeset.change(%{
        narrative: "UNIQUE_OPENING_MARKER: Marta glances up as you push through the door.",
        location_name: "The Weary Pilgrim"
      })
      |> Repo.update()

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))

    assert prompt =~ "## Opening scene (The Weary Pilgrim) — already told to the player"
    assert prompt =~ "This is how the session began. Do not rewrite or re-narrate it."
    # After a move the opening is history: the per-turn "Scene now" wins.
    refute prompt =~ "respond to their action from here"
    assert prompt =~ "UNIQUE_OPENING_MARKER"
    assert prompt =~ opening.narrative
  end

  test "baseline variant: the opening keeps its old wording" do
    {:ok, session} =
      GameSessions.create_session(%{name: "GM Opening Baseline", variant: "baseline"})

    if is_nil(GameSessions.opening_scene(session.id)) do
      Repo.insert!(%Scene{
        game_session_id: session.id,
        location_id: "weary_pilgrim",
        location_name: "The Weary Pilgrim",
        narrative: "Smoke curls under the low beams."
      })
    end

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))

    assert prompt =~ "Do not rewrite or re-narrate this as if it just happened"
    assert prompt =~ "respond to their action from here"
  end

  test "GM prompt omits the opening section when no scene exists yet" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, session} = GameSessions.create_session(%{name: "GM Opening Missing"})
      assert GameSessions.opening_scene(session.id) == nil

      prompt = Context.format_gm_prompt(Context.build_gm_context(session))

      refute prompt =~ "## Opening scene — already told"
      refute prompt =~ "already told to the player"
    end)
  end
end
