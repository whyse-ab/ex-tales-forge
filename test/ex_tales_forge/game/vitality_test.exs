defmodule TalesForge.Game.VitalityTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Fronts.Moves
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction}
  alias TalesForge.Game.TurnProcessor
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  @character %{
    "stats" => %{"CON" => 10, "STR" => 12},
    "skills" => %{"melee_combat" => 1, "climbing" => 3},
    "learning_points" => %{"melee_combat" => 1.0},
    "learning_failures" => %{},
    "wounds" => 0,
    "wound_max" => 3,
    "vitality" => "ok"
  }

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  test "no harm stamps ok vitality and wound_max from CON" do
    world = apply_to(%{"stats" => %{"CON" => 18}}, none())

    assert get_in(world, ["character", "wounds"]) == 0
    assert get_in(world, ["character", "wound_max"]) == 7
    assert get_in(world, ["character", "vitality"]) == "ok"
  end

  test "combat-skill failure inflicts one wound and sets hurt" do
    world = apply_to(@character, fail("melee_combat"))

    assert get_in(world, ["character", "wounds"]) == 1
    assert get_in(world, ["character", "vitality"]) == "hurt"
  end

  test "ranged and unarmed failures also wound" do
    for skill <- ["ranged_combat", "unarmed_combat"] do
      world = apply_to(@character, fail(skill))
      assert get_in(world, ["character", "wounds"]) == 1
      assert get_in(world, ["character", "vitality"]) == "hurt"
    end
  end

  test "visible public_fact harm=wound inflicts one wound" do
    world = apply_to(@character, none(), [%{"id" => "nest_standing_to_arms", "harm" => "wound"}])

    assert get_in(world, ["character", "wounds"]) == 1
    assert get_in(world, ["character", "vitality"]) == "hurt"
  end

  test "combat failure and fact harm still only one wound" do
    world =
      apply_to(@character, fail("melee_combat"), [
        %{"id" => "nest_standing_to_arms", "harm" => "wound"}
      ])

    assert get_in(world, ["character", "wounds"]) == 1
  end

  test "non-combat failure does not wound" do
    world = apply_to(@character, fail("climbing"))

    assert get_in(world, ["character", "wounds"]) == 0
    assert get_in(world, ["character", "vitality"]) == "ok"
  end

  test "hiring_steel without harm does not wound" do
    world =
      apply_to(@character, none(), [
        %{"id" => "hiring_steel", "text" => "retainers", "visibility" => ["valley_inn"]}
      ])

    assert get_in(world, ["character", "wounds"]) == 0
    assert get_in(world, ["character", "vitality"]) == "ok"
  end

  test "hitting cap from below is down, not a death roll" do
    character = Map.merge(@character, %{"wounds" => 2, "vitality" => "hurt"})
    world = apply_to(character, fail("melee_combat"), [], death_roll: 20)

    assert get_in(world, ["character", "wounds"]) == 3
    assert get_in(world, ["character", "vitality"]) == "down"
    assert get_in(world, ["character", "learning_points", "melee_combat"]) == 1.0
  end

  test "excess past cap is a death roll, not wound 4" do
    character = Map.merge(@character, %{"wounds" => 3, "vitality" => "down"})
    world = apply_to(character, fail("melee_combat"), [], death_roll: 20)

    assert get_in(world, ["character", "wounds"]) == 3
    assert get_in(world, ["character", "vitality"]) == "dead"
  end

  test "surviving a death roll stays down and keeps this turn's LP" do
    character = Map.merge(@character, %{"wounds" => 3, "vitality" => "down"})
    world = apply_to(character, fail("melee_combat", 1.0), [], death_roll: 1)

    assert get_in(world, ["character", "wounds"]) == 3
    assert get_in(world, ["character", "vitality"]) == "down"
    assert get_in(world, ["character", "learning_points", "melee_combat"]) == 1.0
  end

  test "fatal death strip this turn's LP and awards no near-death bonus" do
    character =
      Map.merge(@character, %{
        "wounds" => 3,
        "vitality" => "down",
        "learning_points" => %{"melee_combat" => 2.0}
      })

    world = apply_to(character, fail("melee_combat", 1.0), [], death_roll: 20)

    assert get_in(world, ["character", "vitality"]) == "dead"
    assert get_in(world, ["character", "learning_points", "melee_combat"]) == 1.0
  end

  test "already dead is sticky and takes no further harm" do
    character =
      Map.merge(@character, %{
        "wounds" => 3,
        "vitality" => "dead",
        "learning_points" => %{"melee_combat" => 2.0}
      })

    world = apply_to(character, fail("melee_combat", 1.0), [%{"harm" => "wound"}], death_roll: 20)

    assert get_in(world, ["character", "vitality"]) == "dead"
    assert get_in(world, ["character", "wounds"]) == 3
    assert get_in(world, ["character", "learning_points", "melee_combat"]) == 2.0
  end

  test "perform_and_apply does not apply vitality" do
    {updated, _resolution} = Mechanics.perform_and_apply(@character, "melee_combat", 20)

    assert updated["wounds"] == 0
    assert updated["vitality"] == "ok"
    assert Map.get(updated["learning_points"], "melee_combat") > 1.0
  end

  test "raise_alert keeps harm on stringify_fact" do
    state = %{
      "since_tick" => 1,
      "clocks" => %{"alert" => %{"value" => "asleep"}},
      "memories" => [],
      "public_facts" => []
    }

    defn = %{
      "id" => "orc_nest",
      "moves" => %{
        "raise_alert" => %{
          "public_fact" => %{
            "id" => "nest_standing_to_arms",
            "text" => "standing to arms",
            "visibility" => ["orc_nest"],
            "harm" => "wound"
          }
        }
      }
    }

    assert {:ok, updated} = Moves.apply(state, "raise_alert", defn)
    assert hd(updated["public_facts"])["harm"] == "wound"
  end

  test "gm_system forbids wound patches and treats dead as a death" do
    gm = Prompts.gm_system()
    refute gm =~ "You may patch wounds"
    assert gm =~ "Do NOT patch wounds"
    assert gm =~ "dead"
    assert gm =~ "down"
    assert gm =~ "no prize"
  end

  test "dying turn sets session status dead and needs_scene false" do
    {:ok, session} =
      GameSessions.create_session(%{name: "Vitality", adventure_id: "tin_valley"})

    character =
      session.world_state["character"]
      |> Map.merge(%{
        "wounds" => 3,
        "wound_max" => 3,
        "vitality" => "down",
        "learning_points" => %{"melee_combat" => 1.0}
      })

    world = put_in(session.world_state, ["character"], character)

    session =
      session
      |> GameSession.changeset(%{world_state: world})
      |> Repo.update!()

    player_action =
      PlayerAction.decode(%{
        "overall_intent" => "I strike",
        "action" => %{
          "action_type" => "combat",
          "target" => nil,
          "parameters" => %{"skill" => "melee_combat"}
        }
      })

    handler = ActionHandler.resolve(player_action)

    {:ok, payload} =
      TurnProcessor.simulate!(
        session,
        "I strike",
        player_action,
        handler,
        fail("melee_combat", 1.0),
        death_roll: 20
      )

    session = GameSessions.get_session!(session.id)

    assert payload.session_status == "dead"
    assert payload.needs_scene == false
    assert session.status == "dead"
    assert get_in(session.world_state, ["character", "vitality"]) == "dead"
    assert get_in(session.world_state, ["character", "wounds"]) == 3
    assert get_in(session.world_state, ["character", "learning_points", "melee_combat"]) == 0.0
    assert {:error, :dead} = GameSessions.submit_message(session.id, "look around")
  end

  defp apply_to(character, mechanical, facts \\ [], opts \\ []) do
    Mechanics.apply_vitality(
      %{"character" => character, "public_facts" => facts},
      mechanical,
      opts
    )
  end

  defp none, do: %MechanicalResolution{outcome: "none"}

  defp fail(skill, lp \\ 1.0) do
    %MechanicalResolution{skill: skill, outcome: "failure", lp_awarded: lp}
  end
end
