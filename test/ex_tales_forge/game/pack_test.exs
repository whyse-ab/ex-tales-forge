defmodule TalesForge.Game.PackTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Fronts
  alias TalesForge.Game.Fronts, as: FrontDefs
  alias TalesForge.Game.Pack
  alias TalesForge.Game.World
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.FrontInstance

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  defp create_tin_valley_session do
    GameSessions.create_session(%{name: "Tin Valley", adventure_id: "tin_valley"})
  end

  describe "Pack.load/1 tin_valley" do
    test "loads connected graph, pack NPCs, and three fronts" do
      pack = Pack.load("tin_valley")

      assert pack.adventure_id == "tin_valley"
      assert pack.starting_location_id == "valley_inn"
      assert pack.initial_present_npc_ids == ["innkeep"]

      assert Map.has_key?(pack.locations, "valley_inn")
      assert "market_square" in pack.locations["valley_inn"]["exits"]
      assert "orc_approach" in pack.locations["market_square"]["exits"]
      assert "orc_nest" in pack.locations["orc_approach"]["exits"]

      npc_ids = Enum.map(pack.npcs, & &1["id"]) |> Enum.sort()
      assert npc_ids == ["guild_steward", "innkeep", "prospector"]

      by_npc = Map.new(pack.npcs, &{&1["id"], &1})

      assert get_in(by_npc["innkeep"], ["motivations", "current_concern", "focus"]) =~
               "hills are restless"

      assert get_in(by_npc["guild_steward"], ["motivations", "current_concern", "focus"]) =~
               "nest on the cut"

      assert get_in(by_npc["guild_steward"], ["resources", "coin"]) == 12

      assert get_in(by_npc["guild_steward"], [
               "motivations",
               "personality_traits",
               "agreeableness"
             ]) ==
               2

      assert get_in(by_npc["guild_steward"], ["rules"]) != []
      assert get_in(by_npc["guild_steward"], ["moves", "hire_extra", "wage"]) == 5
      assert by_npc["guild_steward"]["name"] == "Osric Vane"

      assert get_in(by_npc["prospector"], ["motivations", "current_concern", "focus"]) =~
               "orcs on the hill"

      assert get_in(by_npc["prospector"], ["motivations", "personality_traits", "agreeableness"]) ==
               6

      refute get_in(by_npc["prospector"], ["moves", "hire_extra"])
      assert get_in(by_npc["prospector"], ["rules"]) in [nil, []]

      assert get_in(by_npc["innkeep"], ["motivations", "primary_need"]) =~
               "warm heart of the valley"

      ale =
        by_npc["innkeep"]
        |> Map.get("stock", [])
        |> Enum.find(&(&1["id"] == "ale_mug"))

      assert ale["price_copper"] == 2
      # Skills are derived at seeding (Characters.Defaults); the pack holds the
      # derive inputs plus the authored overrides only.
      assert by_npc["innkeep"]["derive"]["occupation"] == "innkeep"
      refute Map.has_key?(by_npc["innkeep"], "skills")
      assert by_npc["innkeep"]["fee_copper"] == 50
      assert by_npc["guild_steward"]["skills"] == %{"persuasion" => 9}
      assert by_npc["guild_steward"]["fee_copper"] == 80
      assert by_npc["prospector"]["skills"] == %{"climbing" => 9, "melee_combat" => 8}
      assert by_npc["prospector"]["fee_copper"] == 50

      guild = Enum.find(pack.fronts, &(&1["id"] == "miners_guild"))
      assert guild["identity"] =~ "You are the Miners Guild"
      assert guild["identity"] =~ "Killing a prospector"

      front_ids = Enum.map(pack.fronts, & &1["id"]) |> Enum.sort()
      assert front_ids == ["miners_guild", "orc_nest", "thing_below"]

      statuses = Map.new(pack.fronts, &{&1["id"], &1["status"]})
      assert statuses["orc_nest"] == "live"
      assert statuses["miners_guild"] == "live"
      assert statuses["thing_below"] == "dormant"
    end

    test "raises when adventure directory is missing" do
      assert_raise ArgumentError, ~r/missing/, fn ->
        Pack.load("does_not_exist_pack")
      end
    end
  end

  describe "Game.Fronts.validate!/1" do
    test "raises when portent spawns_front is missing (thing_below contract)" do
      fronts = [
        %{
          "id" => "miners_guild",
          "status" => "live",
          "portents" => [%{"id" => "they_dig_too_deep", "spawns_front" => "thing_below"}]
        }
      ]

      assert_raise ArgumentError, ~r/spawns_front/, fn ->
        FrontDefs.validate!(fronts)
      end
    end

    test "raises when an exit target is missing from locations" do
      pack = Pack.load("tin_valley")
      inn = Map.put(pack.locations["valley_inn"], "exits", ["no_such_place"])
      bad = Map.put(pack.locations, "valley_inn", inn)

      assert_raise ArgumentError, ~r/exit/, fn ->
        Pack.validate_graph!("valley_inn", bad)
      end
    end
  end

  describe "create_session tin_valley" do
    test "materializes start, Elara, pack NPCs, and front rows" do
      assert {:ok, session} = create_tin_valley_session()
      world = session.world_state
      elara = World.default_world_state()["character"]

      assert session.name == "Tin Valley"
      assert world["adventure_id"] == "tin_valley"
      assert world["location_id"] == "valley_inn"
      assert world["character"]["location_id"] == "valley_inn"
      assert world["location_name"] == "Valley Inn"
      assert world["public_facts"] == []

      assert world["situation_lines"] == [
               "You have just pushed through the inn door.",
               "Osric Vane wants the nest off the cut so the Guild can take the hill."
             ]

      assert "market_square" in world["locations"]["valley_inn"]["exits"]

      assert world["character"]["id"] == elara["id"]
      assert world["character"]["stats"] == elara["stats"]
      assert world["character"]["inventory"] == elara["inventory"]
      assert world["character"]["skills"] == elara["skills"]

      npc_ids = Enum.map(session.npc_instances, & &1.npc_id) |> Enum.sort()
      assert npc_ids == ["guild_steward", "innkeep", "prospector"]
      assert world["present_npcs"] == ["innkeep"]

      brenna = NPC.get_instance(session.id, "innkeep")
      osric = NPC.get_instance(session.id, "guild_steward")
      caldern = NPC.get_instance(session.id, "prospector")

      assert get_in(brenna.runtime_state, ["current_concern", "focus"]) =~ "hills are restless"
      assert get_in(osric.runtime_state, ["current_concern", "focus"]) =~ "nest on the cut"
      assert get_in(caldern.runtime_state, ["current_concern", "focus"]) =~ "orcs on the hill"
      assert get_in(osric.personality, ["resources", "coin"]) == 12
      assert get_in(osric.runtime_state, ["resources", "coin"]) == 12
      assert get_in(osric.personality, ["rules"]) != []
      refute Fronts.get_instance(session.id, "guild_steward")

      assert get_in(brenna.personality, ["motivations", "current_concern", "focus"]) =~
               "hills are restless"

      assert brenna.personality["skills"] == %{
               "persuasion" => 8,
               "insight" => 8,
               "etiquette" => 4
             }

      assert brenna.personality["fee_copper"] == 50
      refute Map.has_key?(brenna.runtime_state, "skills")
      refute Map.has_key?(brenna.runtime_state, "fee_copper")

      assert osric.personality["skills"] == %{
               "persuasion" => 9,
               "insight" => 8,
               "etiquette" => 4,
               "intimidation" => 4
             }

      assert osric.personality["fee_copper"] == 80
      refute Map.has_key?(osric.runtime_state, "skills")
      refute Map.has_key?(osric.runtime_state, "fee_copper")

      assert caldern.personality["skills"] == %{
               "climbing" => 9,
               "survival" => 8,
               "melee_combat" => 8,
               "tracking" => 4
             }

      assert caldern.personality["fee_copper"] == 50
      refute Map.has_key?(caldern.runtime_state, "skills")
      refute Map.has_key?(caldern.runtime_state, "fee_copper")

      gm = NPC.format_gm_sections(session.id, ["innkeep"])
      refute gm =~ "fee_copper"
      refute gm =~ ~s("skills")

      assert NPC.get_instance(session.id, "prospector").runtime_state["location_id"] ==
               "mine_workings"

      refute NPC.get_instance(session.id, "miners_guild")
      refute Fronts.get_instance(session.id, "prospector")
      refute NPC.get_instance(session.id, "marta_kellen")
      refute NPC.get_instance(session.id, "worried_merchant")

      fronts = Fronts.list_all(session.id)
      by_id = Map.new(fronts, &{&1.front_id, &1})
      assert map_size(by_id) == 3
      assert by_id["orc_nest"].status == "live"
      assert by_id["miners_guild"].status == "live"
      assert by_id["thing_below"].status == "dormant"
      assert by_id["orc_nest"].runtime_state["clocks"]["alert"]["value"] == "asleep"
      assert by_id["miners_guild"].runtime_state["clocks"]["clear_orcs"]["threshold"] == 8
      assert Enum.sort(world["live_fronts"]) == ["miners_guild", "orc_nest"]

      ale =
        brenna.runtime_state
        |> Map.get("stock", [])
        |> Enum.find(&(&1["id"] == "ale_mug"))

      assert ale["price_copper"] == 2
      assert ale["quantity"] == 99
    end
  end

  describe "create_session crossroads_ledger" do
    test "does not raise on dangling kings_road and seeds Marta and Henrik" do
      assert {:ok, session} = GameSessions.create_session(%{})

      assert session.world_state["adventure_id"] == "crossroads_ledger"
      square = session.world_state["locations"]["crossroads_square"]
      assert square
      assert "kings_road" in (square["exits"] || World.location("crossroads_square")["exits"])

      assert NPC.get_instance(session.id, "marta_kellen")
      assert NPC.get_instance(session.id, "worried_merchant")
      assert Fronts.list_all(session.id) == []
    end
  end

  test "front_id is unique per session" do
    assert {:ok, session} = create_tin_valley_session()

    assert {:error, changeset} =
             %FrontInstance{}
             |> FrontInstance.changeset(%{
               game_session_id: session.id,
               front_id: "orc_nest",
               status: "live",
               definition: %{},
               runtime_state: %{}
             })
             |> Repo.insert()

    assert errors_on(changeset) != %{}
  end
end
