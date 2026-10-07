defmodule TalesForge.CharactersTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Characters
  alias TalesForge.Game.Pack
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{Character, CharacterMemory, GameSession, SessionEvent}

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  defp create(attrs) do
    {:ok, session} = GameSessions.create_session(Map.merge(%{name: "Characters"}, attrs))
    session
  end

  describe "seeding at session create" do
    test "tin_valley: the player character and one gm character per pack NPC" do
      session = create(%{adventure_id: "tin_valley"})
      chars = Characters.list_for_session(session.id)

      assert Enum.map(chars, &{&1.slug, &1.controller}) == [
               {"elara_voss", "player"},
               {"guild_steward", "gm"},
               {"innkeep", "gm"},
               {"prospector", "gm"}
             ]

      elara = Characters.get_by_slug(session.id, "elara_voss")
      assert elara.name == "Elara Voss"
      assert elara.location_id == "valley_inn"
      assert elara.owner_player_id == nil
      assert elara.stats.dex == 14 and elara.stats.cha == 14
      assert elara.skills["persuasion"] == 3
      assert elara.ocean.openness == 7
      assert elara.maslow_level == "esteem"
      assert [%{text: "Make a name for herself on the road", status: "open"}] = elara.concerns
      assert Enum.map(elara.inventory, & &1.id) == ["travel_cloak", "hunting_knife"]
      assert elara.origin["adventure_id"] == "tin_valley"
      assert elara.definition["maslow"] == "esteem"

      steward = Characters.get_by_slug(session.id, "guild_steward")
      assert steward.name == "Osric Vane"
      assert steward.location_id == "market_square"
      assert steward.stats.str in 9..11
      assert steward.ocean.agreeableness == 2
      assert steward.maslow_level == "esteem"
      assert length(steward.concerns) == 2
      assert hd(steward.concerns).since_tick == session.world_state["world_tick"]
      assert steward.relationships == %{"elara_voss" => 0.0}
      assert steward.runtime["resources"] == %{"coin" => 12}

      innkeep = Characters.get_by_slug(session.id, "innkeep")
      assert [%{id: "ale_mug", price_copper: 2}] = innkeep.inventory
      # Derived defaults: skills on the PC scale, authored OCEAN kept, stats within ±1 of 10.
      assert innkeep.skills == %{"persuasion" => 8, "insight" => 8, "etiquette" => 4}
      assert innkeep.ocean.conscientiousness == 7
      assert innkeep.stats.str in 9..11
    end

    test "derived NPC stats are seeded per session and NPC, stable on reload" do
      a = create(%{adventure_id: "tin_valley"})
      b = create(%{adventure_id: "tin_valley"})

      stats = fn s, slug ->
        c = Characters.get_by_slug(s.id, slug)
        Map.take(Map.from_struct(c.stats), ~w(str dex con int wis cha)a)
      end

      inst = TalesForge.NPC.get_instance(a.id, "prospector")

      assert inst.personality["stats"] ==
               TalesForge.NPC.get_instance(a.id, "prospector").personality["stats"]

      for slug <- ~w(innkeep guild_steward prospector) do
        assert Enum.all?(Map.values(stats.(a, slug)), &(&1 in 9..11))
        assert Enum.all?(Map.values(stats.(b, slug)), &(&1 in 9..11))
      end

      # 18 values that each vary by -1/0/+1: the same for two sessions has odds of about 1 in 3^18.
      assert Enum.map(~w(innkeep guild_steward prospector), &stats.(a, &1)) !=
               Enum.map(~w(innkeep guild_steward prospector), &stats.(b, &1))
    end

    test "crossroads: Elara plus the priv/npcs characters" do
      session = create(%{})

      assert session.id |> Characters.list_for_session() |> Enum.map(& &1.slug) ==
               ["elara_voss", "marta_kellen", "worried_merchant"]

      marta = Characters.get_by_slug(session.id, "marta_kellen")
      assert marta.maslow_level == "safety"
      assert marta.mood == "cautious"
      assert Enum.map(marta.concerns, & &1.focus) == ["missing ledger", "unwanted attention"]
    end

    test "controller, controller_ref and owner_player_id reach the player character only" do
      session =
        create(%{
          adventure_id: "tin_valley",
          controller: "bot",
          controller_ref: "paul",
          owner_player_id: "player-1"
        })

      elara = Characters.get_by_slug(session.id, "elara_voss")

      assert {elara.controller, elara.controller_ref, elara.owner_player_id} ==
               {"bot", "paul", "player-1"}

      innkeep = Characters.get_by_slug(session.id, "innkeep")
      assert {innkeep.controller, innkeep.owner_player_id} == {"gm", nil}
      assert Repo.get!(GameSession, session.id).name == "Characters"
    end

    test "seeding again is a no-op" do
      session = create(%{adventure_id: "tin_valley"})
      assert :ok = Characters.seed_session(session)
      assert length(Characters.list_for_session(session.id)) == 4
    end

    test "the session's character map is the pack sheet without levers" do
      for adventure <- ["crossroads_ledger", "tin_valley"] do
        session = create(%{adventure_id: adventure})
        sheet = Pack.sheet(Pack.player_character!(adventure))
        start = session.world_state["location_id"]

        assert session.world_state["character"] == Map.put(sheet, "location_id", start)
        refute Map.has_key?(session.world_state["character"], "maslow")
      end
    end

    test "deleting the session deletes its characters and memories" do
      session = create(%{adventure_id: "tin_valley"})
      elara = Characters.get_by_slug(session.id, "elara_voss")
      {:ok, _} = Characters.add_memory(elara, %{kind: "memory", text: "Arrived", tick: 1})

      Repo.delete!(Repo.get!(GameSession, session.id))

      assert Characters.list_for_session(session.id) == []
      assert Repo.aggregate(CharacterMemory, :count) == 0
    end
  end

  describe "memories" do
    test "rows point at the shared event; each character keeps its own view" do
      session = create(%{adventure_id: "tin_valley"})

      event =
        Repo.insert!(%SessionEvent{
          game_session_id: session.id,
          kind: "world.fact",
          tick: 10,
          payload: %{"text" => "The Guild post was torn down"}
        })

      steward = Characters.get_by_slug(session.id, "guild_steward")
      innkeep = Characters.get_by_slug(session.id, "innkeep")

      {:ok, _} =
        Characters.add_memory(steward, %{
          kind: "memory",
          text: "Someone tore down my post",
          felt: "angry",
          salience: 0.9,
          session_event_id: event.id,
          tick: 10
        })

      {:ok, _} =
        Characters.add_memory(innkeep, %{
          kind: "memory",
          text: "Heard the Guild post came down",
          felt: "amused",
          salience: 0.3,
          secret: true,
          session_event_id: event.id,
          tick: 10
        })

      assert [%{felt: "angry", salience: 0.9}] = Characters.list_memories(steward)
      assert [%{felt: "amused", secret: true}] = Characters.list_memories(innkeep)

      Repo.delete!(event)
      assert [%{session_event_id: nil}] = Characters.list_memories(steward)
    end

    test "memory validation" do
      session = create(%{adventure_id: "tin_valley"})
      elara = Characters.get_by_slug(session.id, "elara_voss")

      assert {:error, cs} = Characters.add_memory(elara, %{kind: "gossip", text: "x"})
      assert %{kind: [_]} = errors_on(cs)

      assert {:error, cs} =
               Characters.add_memory(elara, %{kind: "fact", text: "x", salience: 2.0})

      assert %{salience: [_]} = errors_on(cs)
    end
  end

  describe "Character.changeset/2" do
    setup do
      %{session: create(%{adventure_id: "tin_valley"})}
    end

    defp attrs(session, extra) do
      Map.merge(
        %{
          game_session_id: session.id,
          slug: "extra",
          controller: "gm",
          name: "Extra",
          maslow_level: "safety",
          stats: %{},
          ocean: %{}
        },
        extra
      )
    end

    test "accepts player, gm and bot; defaults stats to 10 and OCEAN to 5", %{session: session} do
      for controller <- Character.controllers() do
        cs = Character.changeset(%Character{}, attrs(session, %{controller: controller}))
        assert cs.valid?
      end

      {:ok, c} = Repo.insert(Character.changeset(%Character{}, attrs(session, %{})))
      assert c.stats.wis == 10
      assert c.ocean.neuroticism == 5
    end

    test "rejects a bad controller, Maslow level, OCEAN value or a fourth concern", %{
      session: session
    } do
      concern = %{text: "c"}

      for {extra, field} <- [
            {%{controller: "robot"}, :controller},
            {%{maslow_level: "wealth"}, :maslow_level},
            {%{ocean: %{openness: 11}}, :ocean},
            {%{concerns: [concern, concern, concern, concern]}, :concerns},
            {%{vitality: "fine"}, :vitality}
          ] do
        cs = Character.changeset(%Character{}, attrs(session, extra))
        refute cs.valid?
        assert Map.has_key?(errors_on(cs), field), "expected an error on #{field}"
      end
    end

    test "slug is unique per session", %{session: session} do
      assert {:error, cs} =
               Repo.insert(Character.changeset(%Character{}, attrs(session, %{slug: "innkeep"})))

      assert %{game_session_id: _} = errors_on(cs)
    end

    test "the database rejects an unknown controller", %{session: session} do
      assert_raise Postgrex.Error, ~r/characters_controller_check/, fn ->
        Repo.insert_all("characters", [
          %{
            id: Ecto.UUID.bingenerate(),
            game_session_id: Ecto.UUID.dump!(session.id),
            slug: "raw",
            controller: "robot",
            name: "Raw",
            maslow_level: "safety",
            inserted_at: DateTime.utc_now(:second),
            updated_at: DateTime.utc_now(:second)
          }
        ])
      end
    end
  end
end
