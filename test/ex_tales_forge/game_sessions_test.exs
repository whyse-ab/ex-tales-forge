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

  describe "answering a clarification" do
    import TalesForge.PlaytestHelpers

    setup do
      on_exit(fn ->
        System.put_env("LLM_PROVIDER", "mock")
        System.delete_env("XAI_API_KEY")
        System.delete_env("TIER1_HEURISTIC_THRESHOLD")
      end)

      {:ok, session} =
        GameSessions.create_session(%{name: "Which way", adventure_id: "tin_valley"})

      # Every action goes to the intent LLM, which asks back.
      System.put_env("TIER1_HEURISTIC_THRESHOLD", "1.0")
      stub_llm(fn kind, _user -> if kind == :intent, do: clarifying_intent(), else: :default end)

      assert {:ok, %{status: :clarification, clarification: question}} =
               GameSessions.submit_message(session.id, "I go over there.")

      {:ok, session: session, question: question}
    end

    test "the pending question keeps the player's words", %{session: session, question: q} do
      pending = GameSessions.pending_clarification(Repo.get!(GameSession, session.id).world_state)

      assert pending["clarification_id"] == q["clarification_id"]
      assert pending["player_text"] == "I go over there."
      refute Map.has_key?(q, "player_text")
      assert GameSessions.pending_clarification(%{}) == nil
      assert GameSessions.pending_clarification(nil) == nil
    end

    test "a picked option with no text plays the words the question was about",
         %{session: session, question: q} do
      assert {:ok, %{status: :processing}} =
               GameSessions.submit_message(session.id, "",
                 clarification_id: q["clarification_id"],
                 option_id: "inn"
               )

      assert [%Turn{player_action: "I go over there."}] = turns(session.id)

      assert GameSessions.pending_clarification(Repo.get!(GameSession, session.id).world_state) ==
               nil
    end

    test "a picked option with text plays that text (the persona bot sends the label)",
         %{session: session, question: q} do
      assert {:ok, %{status: :processing}} =
               GameSessions.submit_message(session.id, "Ask the innkeeper",
                 clarification_id: q["clarification_id"],
                 option_id: "inn"
               )

      assert [%Turn{player_action: "Ask the innkeeper"}] = turns(session.id)
    end

    test "a question that has passed is an error, not a crash", %{session: session} do
      assert {:error, :clarification_expired} =
               GameSessions.submit_message(session.id, "",
                 clarification_id: "gone",
                 option_id: "inn"
               )

      assert {:error, :clarification_expired} =
               GameSessions.submit_message(session.id, "the inn", clarification_id: "gone")

      assert turns(session.id) == []
    end

    test "blank text without an option is still empty", %{session: session, question: q} do
      assert {:error, :empty_message} = GameSessions.submit_message(session.id, "  ")

      assert {:error, :empty_message} =
               GameSessions.submit_message(session.id, "",
                 clarification_id: q["clarification_id"]
               )
    end
  end

  defp turns(session_id) do
    Turn
    |> Repo.all()
    |> Enum.filter(&(&1.game_session_id == session_id))
  end

  defp clarifying_intent do
    %{
      "overall_intent" => "go somewhere",
      "actions" => [
        %{"action_type" => "speak", "target" => "innkeep", "parameters" => %{}},
        %{"action_type" => "move", "target" => "market_square", "parameters" => %{}}
      ],
      "primary_index" => 0,
      "confidence" => 0.4,
      "needs_clarification" => true,
      "clarification_question" => "Which way?",
      "clarification_options" => [
        %{"id" => "inn", "label" => "Ask the innkeeper", "action_index" => 0},
        %{"id" => "square", "label" => "Walk to the square", "action_index" => 1}
      ]
    }
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
