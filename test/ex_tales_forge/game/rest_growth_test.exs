defmodule TalesForge.Game.RestGrowthTest do
  @moduledoc """
  Skill growth from failure, banked until sleep (decision 2026-10-09): on a
  long rest the skills that improved reach the per-turn part of the GM prompt,
  so the GM can let the character wake surer of them. Ordinary turns and the
  baseline variant add nothing.
  """
  use TalesForge.DataCase, async: false

  import TalesForge.PlaytestHelpers, only: [stub_llm: 1]

  alias TalesForge.Game.Context
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Reflection
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Schemas.GameSession

  doctest Context, only: [rest_growth_section: 1]
  doctest Reflection

  @heading "## Rest: what sank in"

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
        %{"narrative" => "Morning light.", "gm_notes" => "n"}

      _kind, _user, _system ->
        :default
    end)

    :ok
  end

  # Twenty banked chances on an untrained skill: each attempt is a coin flip,
  # so at least one improves (all twenty failing is about 1 in a million).
  defp play(variant, text, level \\ 0) do
    {:ok, session} =
      GameSessions.create_session(%{adventure_id: "tin_valley", variant: variant})

    # Reload: the opening scene has been written since create_session returned.
    session = GameSessions.get_session!(session.id)

    world =
      Map.update!(session.world_state, "character", fn character ->
        character
        |> Map.update("skills", %{"stealth" => level}, &Map.put(&1, "stealth", level))
        |> Map.put("learning_points", %{"stealth" => 20.0})
        |> Map.put("learning_failures", %{"stealth" => 20})
      end)

    session |> GameSession.changeset(%{world_state: world}) |> Repo.update!()

    assert {:ok, _} = GameSessions.submit_message(session.id, text)
    assert_received {:gm_prompt, user}
    {user, GameSessions.get_session!(session.id)}
  end

  test "default: sleep resolves the banked chances and tells the GM, without numbers" do
    {user, session} = play("default", "I go to sleep")

    assert user =~ @heading
    assert user =~ "They wake a little surer at: stealth."
    [stable | _] = String.split(user, "## Perceived facts")
    refute stable =~ @heading
    assert get_in(session.world_state, ["character", "skills", "stealth"]) > 0
    assert get_in(session.world_state, ["character", "learning_points", "stealth"]) == 0.0
  end

  test "default: an ordinary turn keeps the chances banked and adds nothing" do
    {user, session} = play("default", "I look around the common room")

    refute user =~ @heading
    assert get_in(session.world_state, ["character", "learning_points", "stealth"]) == 20.0
  end

  test "default: from level 10 an unreflected skill keeps its LP and the GM hears why" do
    {user, session} = play("default", "I go to sleep", 10)

    assert user =~ "Their stealth has outgrown simple practice; they need to reflect on it"
    refute user =~ "They wake a little surer"
    assert get_in(session.world_state, ["character", "learning_points", "stealth"]) == 20.0
  end

  test "default: reflecting on the skill at the rest lets it grow" do
    {user, session} =
      play("default", "I go to sleep after going over my sneaking past the guards", 10)

    refute user =~ "outgrown simple practice"
    assert get_in(session.world_state, ["character", "learning_points", "stealth"]) == 0.0
  end

  test "the reflection words cover every skill the game rolls" do
    assert Reflection.covered_skills() == Mechanics.skill_stat_map() |> Map.keys() |> Enum.sort()
  end

  test "baseline: the prompt never gets the note" do
    {user, _session} = play("baseline", "I go to sleep")
    refute user =~ @heading
  end
end
