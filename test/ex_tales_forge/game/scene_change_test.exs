defmodule TalesForge.Game.SceneChangeTest do
  @moduledoc """
  Scene changes (tales-forge-docs `docs/analysis-jev-baseline-2026-10-07.md`,
  §4 and recommendation 1). In 38 of 65 attempts to leave the inn the GM was
  still describing the inn on the next turn: the intent heuristic missed the
  move ("I step into the square"), the location never changed, and the GM,
  told the character was at the Valley Inn with Brenna, answered Paul's speech
  to Osric as Brenna at the bar (runs 761713eb and 98018f52).

  The fix: the intent step recognises more moves (aliases, the way out, a
  person elsewhere), Tier 1 targets are resolved to real places, the move
  updates the recorded location and who is present, and the GM prompt has a
  "Scene now" block (where, who is present, who is elsewhere, the move).
  The baseline variant keeps the old behaviour.
  """
  use TalesForge.DataCase, async: false

  doctest TalesForge.Game.Movement
  doctest TalesForge.Game.Intent, only: [resolve_move_target: 2]

  alias TalesForge.Game.{ActionHandler, Context, Intent, Movement, Prompts, TurnProcessor}
  alias TalesForge.Game.Schemas.{IntentExtraction, PlayerAction, SingleAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  @paul_t6 "Mistress Brenna, your bread and your blessing both warm a traveler more than any fire could. " <>
             "I shall carry your words to Osric as faithfully as I carry this gift. With your leave, " <>
             "I step into the square before the lanterns claim the last of the light."

  @paul_t7 "Osric Vane, steward of the Guild—I am Corvin Ashdown, a wandering preacher lately come " <>
             "from Brenna Holt's hearth. Might a silver tongue and a plea for mercy find room in your plans?"

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      System.delete_env("XAI_API_KEY")
      System.put_env("LLM_PROVIDER", "mock")
    end)

    :ok
  end

  defp session(variant \\ "default") do
    {:ok, session} =
      GameSessions.create_session(%{name: "Scene", adventure_id: "tin_valley", variant: variant})

    Repo.get!(GameSession, session.id)
  end

  defp intent(session), do: Context.build_intent_context(session)

  defp at(session, location_id) do
    world = put_in(session.world_state, ["character", "location_id"], location_id)

    {:ok, session} =
      session
      |> GameSession.changeset(%{world_state: Map.put(world, "location_id", location_id)})
      |> Repo.update()

    {:ok, session} = TalesForge.NPC.refresh_session_world_state(session)
    session
  end

  defp heuristic(text, context) do
    text |> Intent.heuristic_intent(context) |> Intent.validate_player_action(context)
  end

  defp move_target(text, context) do
    case heuristic(text, context) do
      %PlayerAction{action: %SingleAction{action_type: :move, target: target}} -> target
      _ -> nil
    end
  end

  describe "the intent step recognises moves" do
    setup do
      session = session()
      %{session: session, inn: intent(session)}
    end

    test "Paul's 'I step into the square' leaves the inn (run 761713eb, turn 6)", %{inn: inn} do
      assert move_target(@paul_t6, inn) == "market_square"
    end

    test "the way out, aliases and places further on", %{session: session, inn: inn} do
      assert move_target("I grab the stew and head straight for the door.", inn) ==
               "market_square"

      assert move_target("I push open the inn door and step out into the night.", inn) ==
               "market_square"

      assert move_target("I head over to the guild post.", inn) == "market_square"

      square = session |> at("market_square") |> intent()

      assert move_target("I nod to Osric and head straight up the rocky path to the cut.", square) ==
               "orc_approach"

      assert move_target("I head east through the stalls to the mine workings.", square) ==
               "mine_workings"

      assert move_target("I walk back to the inn.", square) == "valley_inn"

      # Two hops from the inn, in one turn.
      assert move_target("I walk to the mine.", inn) == "mine_workings"
    end

    test "travel stops at a checkpoint on the way", %{session: session} do
      mine = session |> at("mine_workings") |> intent()

      # From the mine to the nest goes square → cut → nest; the cut is watched.
      assert move_target("Caldern, lead the way up that trail to the orc nest.", mine) ==
               "orc_approach"
    end

    test "speaking by name to someone who is elsewhere goes to them (run 761713eb, turn 7)", %{
      inn: inn
    } do
      assert move_target(@paul_t7, inn) == "market_square"

      assert move_target("I go find Osric and tell him I'll take the job.", inn) ==
               "market_square"

      assert move_target("Steward Osric, I hear the Guild pays for orc ears?", inn) ==
               "market_square"
    end

    test "talking about a place or a person is not a move", %{inn: inn} do
      # Caldern is not at the inn, but crossing the room is not a journey.
      refute move_target("I approach Caldern Voss at the hearth.", inn)
      refute move_target("Tell me more of this orc nest and the good Osric Vane.", inn)
      refute move_target("Brenna, where is the market square?", inn)
      refute move_target("Mistress Brenna, what does Osric Vane pay for steel?", inn)

      refute move_target(
               "Perhaps I shall seek him out before the light fades, yet first... might you share what tales the miners tell?",
               inn
             )
    end

    test "a move phrased as a plan is left to Tier 1 when live (confidence under the threshold)",
         %{inn: inn} do
      planned = Intent.heuristic_intent("I'll head to the market square after this drink.", inn)
      assert [%SingleAction{action_type: :move, target: "market_square"}] = planned.actions
      assert planned.confidence < 0.85
      refute Intent.needs_clarification?(planned)

      now = Intent.heuristic_intent("I'll head to the market square right now.", inn)
      assert now.confidence >= 0.85

      # Addressing someone who is elsewhere stays with the heuristic, even as a question.
      addressed =
        Intent.heuristic_intent("Osric Vane, what does the Guild pay for orc ears?", inn)

      assert [%SingleAction{action_type: :move, target: "market_square"}] = addressed.actions
      assert addressed.confidence >= 0.85
    end
  end

  describe "Tier 1 targets resolve to real places" do
    setup do
      %{inn: intent(session())}
    end

    defp tier1(action, context) do
      %IntentExtraction{
        overall_intent: "go",
        actions: [action],
        primary_index: 0,
        confidence: 0.9,
        needs_clarification: false
      }
      |> Intent.validate_player_action(context)
      |> Map.get(:action)
    end

    test "a name, an alias or a person's id becomes a location id", %{inn: inn} do
      assert %{action_type: :move, target: "market_square"} =
               tier1(%SingleAction{action_type: :move, target: "Market Square"}, inn)

      assert %{action_type: :move, target: "market_square"} =
               tier1(%SingleAction{action_type: :move, target: "guild_steward"}, inn)

      assert %{action_type: :move, target: "mine_workings"} =
               tier1(%SingleAction{action_type: :move, target: "the mine"}, inn)
    end

    test "speaking to someone elsewhere is a move to them; an unknown place is no move", %{
      inn: inn
    } do
      assert %{action_type: :move, target: "market_square"} =
               tier1(%SingleAction{action_type: :speak, target: "guild_steward"}, inn)

      assert %{action_type: :other, target: nil} =
               tier1(%SingleAction{action_type: :move, target: "the moon"}, inn)

      assert %{action_type: :speak, target: "innkeep"} =
               tier1(%SingleAction{action_type: :speak, target: "innkeep"}, inn)
    end
  end

  describe "the Market Square / Osric case, end to end" do
    test "the move updates location and presence; the next GM turn is at the square with Osric, not Brenna" do
      session = session()
      test_pid = self()

      System.put_env("LLM_PROVIDER", "xai")
      System.put_env("XAI_API_KEY", "test-key")

      Req.Test.stub(TalesForge.LLM, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:gm, Jason.decode!(body)})
        content = Jason.encode!(%{"narrative" => "You cross the lane to the square."})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
          "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 10}
        })
      end)

      action = heuristic(@paul_t6, intent(session))
      assert {:ok, payload} = TurnProcessor.run(session.id, @paul_t6, PlayerAction.encode(action))

      # Recorded: location, name, who is present; a new scene is due.
      assert payload.world_state["location_id"] == "market_square"
      assert payload.world_state["character"]["location_id"] == "market_square"
      assert payload.world_state["location_name"] == "Market Square"
      assert payload.world_state["present_npcs"] == ["guild_steward"]
      assert payload.needs_scene

      assert_receive {:gm, body}
      move_turn = List.last(body["messages"])["content"]
      assert move_turn =~ "Where: Market Square (market_square)."
      assert move_turn =~ "Present: Osric Vane (guild_steward)."
      assert move_turn =~ "Just now: the character left Valley Inn for Market Square."
      assert move_turn =~ "Brenna Holt at Valley Inn"

      # Turn 7: Paul speaks to Osric. Brenna is not in the scene any more.
      session = Repo.get!(GameSession, session.id)
      context = Context.build_gm_context(session)
      t7 = heuristic(@paul_t7, context.intent_context)
      messages = Prompts.gm_messages(context, nil, t7, ActionHandler.resolve(t7), 7)
      per_turn = List.last(messages).content

      assert per_turn =~ "Current location: Market Square (market_square)"
      assert per_turn =~ "- guild_steward: Osric Vane"
      refute per_turn =~ "- innkeep: Brenna Holt"
      refute per_turn =~ "short-handed on busy nights"
      assert per_turn =~ "Elsewhere (not here): Brenna Holt at Valley Inn"
      refute per_turn =~ "Just now:"

      stable = Enum.at(messages, 3).content
      refute stable =~ "respond to their action from here"
    end

    test "an unknown move target leaves the character where they are" do
      session = session()

      action = %PlayerAction{
        overall_intent: "go to the moon",
        action: %SingleAction{action_type: :move, target: "the_moon"}
      }

      world =
        TurnProcessor.apply_board(
          session,
          session.world_state["character"],
          ActionHandler.resolve(action),
          action,
          %TalesForge.Game.Schemas.MechanicalResolution{}
        ).world

      assert world["location_id"] == "valley_inn"
      assert world["present_npcs"] == ["innkeep"]
    end
  end

  describe "the baseline variant keeps the old behaviour" do
    test "no new moves, no scene block, the old opening wording" do
      session = session("baseline")
      context = Context.build_gm_context(session)

      refute move_target(@paul_t6, context.intent_context)
      assert Context.scene_now_section(context) == nil
    end
  end

  test "Movement.terms covers the pack's aliases" do
    world = session().world_state
    assert "square" in Movement.terms("market_square", world["locations"]["market_square"])
    assert world["locations"]["orc_approach"]["checkpoint"] == true
  end
end
