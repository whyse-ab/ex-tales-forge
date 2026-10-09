defmodule TalesForge.Game.GesturePromptTest do
  @moduledoc """
  The GM's recent gestures reach the next GM prompt as spent, in the per-turn
  part only, for the default variant; a repeat is logged. The baseline variant's
  prompts are untouched.
  """
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog
  import TalesForge.PlaytestHelpers, only: [stub_llm: 1]

  alias TalesForge.GameSessions
  alias TalesForge.Jido

  @narrative "Brenna wipes her hands on her apron and leans an elbow on the bar."

  setup do
    mode = Application.get_env(:ex_tales_forge, :intent_jev)

    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)

      if mode,
        do: Application.put_env(:ex_tales_forge, :intent_jev, mode),
        else: Application.delete_env(:ex_tales_forge, :intent_jev)

      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
    end)

    Application.put_env(:ex_tales_forge, :intent_jev, :off)
    test_pid = self()

    stub_llm(fn
      :gm, user, system ->
        send(test_pid, {:gm_prompt, system, user})
        %{"narrative" => @narrative, "gm_notes" => "n"}

      _kind, _user, _system ->
        :default
    end)

    :ok
  end

  defp two_turns(variant) do
    {:ok, session} =
      GameSessions.create_session(%{adventure_id: "tin_valley", variant: variant})

    assert {:ok, _} =
             GameSessions.submit_message(session.id, "I ask the innkeeper about the road")

    assert_received {:gm_prompt, _system, first_user}

    log =
      capture_log(fn ->
        assert {:ok, _} = GameSessions.submit_message(session.id, "I ask about the mine")
      end)

    assert_received {:gm_prompt, system, second_user}
    %{first: first_user, second: second_user, system: system, log: log}
  end

  test "default: the second GM prompt lists the first turn's gestures, and a repeat is logged" do
    %{first: first, second: second, system: system, log: log} = two_turns("default")

    refute first =~ "Gestures already used"

    assert second =~
             "## Gestures already used (recent turns)\n- wipes her hands\n- leans an elbow\n"

    assert system =~ ~s|Sometimes the per-turn state has "Gestures already used (recent turns)"|
    refute system =~ "Banned stock phrases"

    assert log =~ "gm gesture repeated"
    assert log =~ "key=wipe:hand"
    assert log =~ "key=lean:elbow"
  end

  test "default: the list sits in the per-turn message, after the session-stable part" do
    %{second: second} = two_turns("default")
    [stable | _] = String.split(second, "## Perceived facts")
    refute stable =~ "Gestures already used"
  end

  test "baseline: no gesture list, no new rule, no repeat log" do
    %{second: second, system: system, log: log} = two_turns("baseline")

    refute second =~ "Gestures already used"
    refute system =~ "Gestures already used"
    refute log =~ "gm gesture repeated"
  end
end
