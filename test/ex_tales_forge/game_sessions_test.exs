defmodule TalesForge.GameSessionsTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, Turn}

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  test "submit_message enqueues a turn and persists GM narration" do
    assert {:ok, session} = GameSessions.create_session(%{name: "Test Session"})

    assert {:ok, %{status: :processing}} =
             GameSessions.submit_message(session.id, "look around the tavern")

    turns =
      Turn
      |> Repo.all()
      |> Enum.filter(&(&1.game_session_id == session.id))

    assert length(turns) == 1
    turn = List.first(turns)
    assert turn.turn_number == 1
    assert turn.player_action == "look around the tavern"
    assert is_binary(turn.narrative)
    assert turn.narrative != ""
  end

  test "submit_message applies server mechanics on skill checks" do
    assert {:ok, session} = GameSessions.create_session(%{name: "Mechanics"})

    assert {:ok, %{status: :processing}} =
             GameSessions.submit_message(session.id, "search the chalked slate")

    turn =
      Turn
      |> Repo.all()
      |> Enum.find(&(&1.game_session_id == session.id))

    assert turn.mechanical_resolution["outcome"] in ["success", "partial_success", "failure"]
    assert is_integer(turn.mechanical_resolution["roll"])

    session = GameSessions.get_session!(session.id)
    lp = get_in(session.world_state, ["character", "learning_points"])
    assert is_map(lp)
  end

  test "submit_message rejects dead sessions before intent" do
    assert {:ok, session} = GameSessions.create_session(%{name: "Dead"})

    session
    |> GameSession.changeset(%{status: "dead"})
    |> Repo.update!()

    assert {:error, :dead} = GameSessions.submit_message(session.id, "look around the tavern")

    turns =
      Turn
      |> Repo.all()
      |> Enum.filter(&(&1.game_session_id == session.id))

    assert turns == []
  end
end
