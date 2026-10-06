defmodule TalesForge.SceneProcessorTest do
  use TalesForge.DataCase, async: false

  import Ecto.Query

  alias TalesForge.Game.SceneProcessor
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{Scene, Turn}
  alias TalesForge.Workers.ProcessScene

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  test "create_session opens with a scene before player can act" do
    assert {:ok, session} = GameSessions.create_session(%{name: "Scene Test"})

    scene =
      Scene
      |> Repo.get_by(game_session_id: session.id, location_id: "weary_pilgrim")

    assert scene
    assert scene.narrative != ""

    session = GameSessions.get_session!(session.id)
    assert session.world_state["last_scene_location"] == "weary_pilgrim"
    refute SceneProcessor.needs_scene?(session.world_state)
  end

  test "submit_message works after the opening scene" do
    assert {:ok, session} = GameSessions.create_session(%{name: "Scene Then Turn"})

    assert {:ok, %{status: :processing}} =
             GameSessions.submit_message(session.id, "look around the tavern")

    turn =
      Turn
      |> Repo.get_by(game_session_id: session.id, turn_number: 1)

    assert turn
    assert turn.player_action == "look around the tavern"
  end

  test "a finished scene job does not block the next scene for the session" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      args = %{session_id: Ecto.UUID.generate()}
      {:ok, first} = Oban.insert(ProcessScene.new(args))
      assert {:ok, %{conflict?: true}} = Oban.insert(ProcessScene.new(args))

      Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [state: "completed"])
      assert {:ok, %{conflict?: false}} = Oban.insert(ProcessScene.new(args))
    end)
  end

  test "travel sets needs_scene until a new scene is described" do
    assert {:ok, session} = GameSessions.create_session(%{name: "Travel Scene"})

    assert {:ok, %{status: :processing}} =
             GameSessions.submit_message(session.id, "I head outside to Crossroads Square")

    session = GameSessions.get_session!(session.id)
    assert session.world_state["location_id"] == "crossroads_square"
    assert SceneProcessor.needs_scene?(session.world_state)

    assert {:ok, _} = GameSessions.ensure_scene(session)

    session = GameSessions.get_session!(session.id)
    refute SceneProcessor.needs_scene?(session.world_state)

    square_scene =
      Scene
      |> Repo.get_by(game_session_id: session.id, location_id: "crossroads_square")

    assert square_scene
  end
end
