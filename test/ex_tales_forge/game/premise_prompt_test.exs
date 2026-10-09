defmodule TalesForge.Game.PremisePromptTest do
  @moduledoc """
  A false claim in the player's words reaches the GM as a short correction in
  the per-turn part of the prompt, for the default variant, and is recorded on
  the turn as a `player.false_premise` event. The baseline variant's prompts
  are untouched.
  """
  use TalesForge.DataCase, async: false

  import Ecto.Query
  import TalesForge.PlaytestHelpers, only: [stub_llm: 1]

  alias TalesForge.Game.Context
  alias TalesForge.Game.PremiseCheck
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Schemas.SessionEvent

  @claim "as I did yesterday when I bought the enchanted armor, I put it on"
  @heading "## Player claims the state doesn't back"

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
      :gm, user, _system ->
        send(test_pid, {:gm_prompt, user})
        %{"narrative" => "Brenna looks at you.", "gm_notes" => "n"}

      _kind, _user, _system ->
        :default
    end)

    :ok
  end

  defp play(variant, text) do
    {:ok, session} =
      GameSessions.create_session(%{adventure_id: "tin_valley", variant: variant})

    assert {:ok, _} = GameSessions.submit_message(session.id, text)
    assert_received {:gm_prompt, user}

    events =
      SessionEvent
      |> where([e], e.game_session_id == ^session.id and e.kind == "player.false_premise")
      |> Repo.all()

    %{user: user, events: events}
  end

  test "default: the correction is in the per-turn part and the turn records it" do
    %{user: user, events: [event]} = play("default", @claim)

    assert user =~ @heading
    assert user =~ "- Player claims to have bought enchanted armor; no such purchase happened"
    [stable | _] = String.split(user, "## Perceived facts")
    refute stable =~ @heading

    refute event.player_aware

    assert [%{"kind" => "purchase", "claim" => "enchanted armor"}] =
             event.payload["claims"]
  end

  test "default: a true claim adds nothing" do
    %{user: user, events: events} = play("default", "I draw my hunting knife and watch the door.")
    refute user =~ @heading
    assert events == []
  end

  test "baseline: no check, no note, no event" do
    %{user: user, events: events} = play("baseline", @claim)
    refute user =~ @heading
    assert events == []
  end

  test "Context.premise_section/1 is nil for the baseline variant even with findings" do
    findings = PremiseCheck.check("I killed the orc chief", %{fronts: [%{id: "orc_nest"}]})
    assert findings != []

    baseline = %{world_state: %{"variant" => "baseline"}, premise_findings: findings}
    default = %{world_state: %{"variant" => "default"}, premise_findings: findings}

    assert Context.premise_section(baseline) == nil
    assert Context.premise_section(default) =~ @heading
  end
end
