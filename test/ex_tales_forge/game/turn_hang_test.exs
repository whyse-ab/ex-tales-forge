defmodule TalesForge.Game.TurnHangTest do
  @moduledoc """
  The turn hang after a Tier 1 intent (post-rework series, 2026-10-08): 3 of
  14 LLM-intent turns never finished (Lars a76294d9 turn 3, Paul 0d1b8222
  turn 7, Lars 1a995c9f turn 3). The intent call returned, the turn job was
  enqueued, and then nothing: no GM call, no log line, no error, until the
  playtest runner's turn timeout.

  Root cause: Tier 1 answered `"parameters": null` for actions that need no
  check (the prompt asks for a skill only when a roll is needed).
  `SingleAction.decode/1` used `Map.get(map, "parameters", %{})`, whose
  default covers only a missing key, so the action kept `parameters: nil`,
  and `ActionHandler.resolve/2` crashed on `Map.get(nil, "skill")`
  (BadMapError). Oban caught the raise, retried three times and discarded the
  job, all without a log line or a `:turn_failed` broadcast.

  The player actions below are the three discarded jobs' args, as stored on
  playtest (`oban_jobs` 1052, 1145 and 1185).
  """
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog
  import TalesForge.PlaytestHelpers

  alias TalesForge.Game.{Context, Intent, TurnProcessor}
  alias TalesForge.Game.Schemas.{IntentExtraction, PlayerAction, SingleAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Playtest.Runner
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Repo
  alias TalesForge.Schemas.{AICall, GameSession, PlaytestRun, Turn}
  alias TalesForge.Workers.ProcessTurn

  doctest TalesForge.Game.Schemas.SingleAction

  @lars_t3_text "I'll head to the market square and talk to Osric Vane about clearing that orc nest. " <>
                  "Sounds like a solid quest worth taking on."

  @hung_jobs [
    {"Lars a76294d9 turn 3 (job 1052)",
     "I'll head to the mine workings this evening to find Caldern Voss and hear about these eyes in the dark myself. " <>
       "If he's still there, maybe I can get him to show me the way up the cut at first light.",
     %{
       "action" => %{"action_type" => "move", "parameters" => nil, "target" => "mine_workings"},
       "confidence" => 0.85,
       "deferred_actions" => [
         %{"action_type" => "interact", "parameters" => nil, "target" => "caldern_voss"}
       ],
       "overall_intent" => "head to the mine workings this evening to find Caldern Voss"
     }},
    {"Paul 0d1b8222 turn 7 (job 1145)",
     "Good Brenna, if no voice of reason has yet reached these orcs, then perhaps the gods have kept that task " <>
       "for a humble preacher's tongue. I shall go to the square at dawn and see what manner of men Osric gathers.",
     %{
       "action" => %{"action_type" => "speak", "parameters" => nil, "target" => "innkeep"},
       "confidence" => 0.85,
       "deferred_actions" => [
         %{"action_type" => "move", "parameters" => nil, "target" => "market_square"}
       ],
       "overall_intent" =>
         "Thank Brenna, declare intent to meet Osric at dawn in the market square to try talking to the orcs."
     }},
    {"Lars 1a995c9f turn 3 (job 1185)", @lars_t3_text,
     %{
       "action" => %{"action_type" => "move", "parameters" => nil, "target" => "market_square"},
       "confidence" => 0.85,
       "deferred_actions" => [
         %{"action_type" => "speak", "parameters" => nil, "target" => "osric_vane"}
       ],
       "overall_intent" =>
         "head to the market square to talk to Osric Vane about the orc-clearing job"
     }}
  ]

  # Tier 1's reply for Lars's turn 3, as the job args show it was read.
  @lars_t3_tier1 %{
    "overall_intent" =>
      "head to the market square to talk to Osric Vane about the orc-clearing job",
    "actions" => [
      %{"action_type" => "move", "target" => "market_square", "parameters" => nil},
      %{"action_type" => "speak", "target" => "osric_vane", "parameters" => nil}
    ],
    "primary_index" => 0,
    "confidence" => 0.85,
    "needs_clarification" => false,
    "clarification_question" => nil,
    "clarification_options" => []
  }

  @env ~w(INN_WORLD WORLD_ANTAGONIST TIER1_HEURISTIC_THRESHOLD)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)

    on_exit(fn ->
      for pid <- Task.Supervisor.children(TalesForge.Playtest.Supervisor),
          do: Task.Supervisor.terminate_child(TalesForge.Playtest.Supervisor, pid)

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
      Application.delete_env(:ex_tales_forge, :playtest_runner_enabled)
    end)

    # The hung sessions had both world features.
    System.put_env("INN_WORLD", "on")
    System.put_env("WORLD_ANTAGONIST", "on")
    :ok
  end

  defp session do
    {:ok, session} =
      GameSessions.create_session(%{name: "Hang", adventure_id: "tin_valley"})

    Repo.get!(GameSession, session.id)
  end

  defp turn_count(session_id),
    do: Repo.aggregate(from(t in Turn, where: t.game_session_id == ^session_id), :count)

  describe "the three hung turns, replayed from their stored job args" do
    for {label, raw_action, player_action} <- @hung_jobs do
      test "#{label} completes and broadcasts turn_completed" do
        session = session()
        SessionPubSub.subscribe(session.id)

        job = %Oban.Job{
          args: %{
            "session_id" => session.id,
            "raw_action" => unquote(raw_action),
            "player_action" => unquote(Macro.escape(player_action))
          }
        }

        assert ProcessTurn.perform(job) == :ok
        assert_received {:turn_completed, _payload}
        refute_received {:turn_failed, _}
        assert turn_count(session.id) == 1
      end
    end

    test "the move goes through: Lars is at the square after turn 3 (job 1185)" do
      session = session()
      {_label, raw_action, player_action} = List.last(@hung_jobs)

      assert {:ok, payload} = TurnProcessor.run(session.id, raw_action, player_action)
      assert payload.world_state["location_id"] == "market_square"
    end
  end

  describe "JSON null counts as missing in the intent decoders" do
    test "Tier 1's reply with null parameters becomes actions with empty parameters" do
      extraction = IntentExtraction.decode(@lars_t3_tier1)

      assert [
               %SingleAction{action_type: :move, target: "market_square", parameters: %{}},
               %SingleAction{action_type: :speak, target: "osric_vane", parameters: %{}}
             ] = extraction.actions

      session = session()
      context = Context.build_intent_context(session)
      action = Intent.validate_player_action(extraction, context)

      assert %PlayerAction{action: %SingleAction{parameters: %{}}, deferred_actions: [deferred]} =
               action

      assert deferred.parameters == %{}
      assert PlayerAction.decode(PlayerAction.encode(action)) == action
    end

    test "other null fields take their defaults" do
      nulls = %{
        "overall_intent" => nil,
        "actions" => nil,
        "primary_index" => nil,
        "confidence" => nil,
        "needs_clarification" => nil,
        "clarification_options" => nil
      }

      assert %IntentExtraction{
               overall_intent: "",
               actions: [],
               primary_index: 0,
               confidence: 1.0,
               needs_clarification: false,
               clarification_options: []
             } = IntentExtraction.decode(nulls)

      assert %PlayerAction{
               overall_intent: "",
               action: %SingleAction{action_type: :other, parameters: %{}},
               confidence: 1.0,
               deferred_actions: []
             } =
               PlayerAction.decode(%{
                 "overall_intent" => nil,
                 "action" => nil,
                 "confidence" => nil,
                 "deferred_actions" => nil
               })

      assert %SingleAction{action_type: :other, parameters: %{}} =
               SingleAction.decode(%{"action_type" => nil, "parameters" => "skill"})
    end
  end

  describe "end to end: a playtest run with Tier 1 answering null parameters" do
    test "Lars's run (1a995c9f) plays its turn instead of timing out" do
      # Every action goes to Tier 1, as Lars's plan-phrased move did.
      System.put_env("TIER1_HEURISTIC_THRESHOLD", "1.0")

      stub_llm(fn
        :persona, _user -> %{"action" => @lars_t3_text, "option_id" => nil}
        :intent, _user -> @lars_t3_tier1
        _kind, _user -> :default
      end)

      {:ok, run_id} =
        Runner.start("lars", "tin_valley", turn_limit: 1, turn_timeout_ms: 3_000)

      assert {:ok, %{status: "finished", stop_reason: "turn_limit", turns_played: 1} = run} =
               await(run_id)

      session = Repo.get!(GameSession, run.game_session_id)
      assert session.world_state["location_id"] == "market_square"
    end
  end

  describe "a crashed turn step is no longer silent" do
    setup do
      session = session()

      # A world_state the rules step cannot read: any crash inside the turn.
      session
      |> GameSession.changeset(%{
        world_state: Map.put(session.world_state, "character", "corrupt")
      })
      |> Repo.update!()

      %{session: session}
    end

    test "it is logged with its stacktrace, broadcast as turn_failed, recorded and re-raised for Oban",
         %{session: session} do
      SessionPubSub.subscribe(session.id)
      {_label, raw_action, player_action} = List.last(@hung_jobs)

      job = %Oban.Job{
        args: %{
          "session_id" => session.id,
          "raw_action" => raw_action,
          "player_action" => player_action
        }
      }

      log =
        capture_log(fn ->
          assert_raise FunctionClauseError, fn -> ProcessTurn.perform(job) end
        end)

      assert log =~ "turn processor crashed session=#{session.id} turn=1"
      assert log =~ "FunctionClauseError"
      assert log =~ "turn_processor.ex"

      assert_received {:turn_failed, "crashed: FunctionClauseError"}

      steps =
        Repo.all(
          from(c in AICall,
            where: c.game_session_id == ^session.id and c.call_type == "function",
            select: {c.purpose, c.status}
          )
        )

      assert {"turn.rules", "error"} in steps
      assert turn_count(session.id) == 0
    end

    test "the playtest runner fails the run with the error once every attempt has failed",
         %{session: session} do
      state = %{run: %{game_session_id: session.id}, timeout_ms: 2_000}

      for _attempt <- 1..3, do: send(self(), {:turn_failed, "crashed: FunctionClauseError"})

      assert Runner.await_event(state, {:turn, 0}) == {:error, "crashed: FunctionClauseError"}
    end
  end

  test "a run's flags record the session's world features" do
    stub_llm(fn _kind, _user -> :default end)

    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1)
    assert {:ok, _run} = await(run_id)

    assert %{"inn_world" => "on", "world_antagonist" => "on"} =
             Repo.get!(PlaytestRun, run_id).flags

    System.delete_env("WORLD_ANTAGONIST")
    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1, variant: "baseline")
    assert {:ok, _run} = await(run_id)

    assert %{"inn_world" => "off", "world_antagonist" => "off"} =
             Repo.get!(PlaytestRun, run_id).flags
  end
end
