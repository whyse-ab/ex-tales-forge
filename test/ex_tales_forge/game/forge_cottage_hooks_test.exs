defmodule TalesForge.Game.ForgeCottageHooksTest do
  @moduledoc """
  INN_WORLD: rumours and hooks pull players toward Brask's forge and Maude's
  cottage (decision 2026-10-08 "The forge and Maude's cottage pull players in
  through rumours and hooks"). Hilde and Maude carry a rumour each that is
  heard at the inn, in the yard and in the square; Brenna and Tam send people
  there; with the Tinjacks, Brenna also points at Maude because of Pip. Pack
  data only; sessions without the flag and the baseline variant are unchanged.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.{Context, Pack, Perception}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  @rumours ~w(maude_west_road_news smith_night_work)

  setup do
    previous =
      for key <- ~w(INN_WORLD WORLD_ANTAGONIST), into: %{}, do: {key, System.get_env(key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    System.delete_env("INN_WORLD")
    System.delete_env("WORLD_ANTAGONIST")
    :ok
  end

  defp npc(pack, id), do: Enum.find(pack.npcs, &(&1["id"] == id))

  defp people(pack) do
    for npc <- pack.npcs do
      %{
        npc_id: npc["id"],
        runtime_state: %{
          "location_id" => npc["default_location_id"],
          "public_facts" => npc["public_facts"] || []
        }
      }
    end
  end

  defp heard_at(pack, place) do
    %{"location_id" => place}
    |> Perception.visible_world(people(pack), [])
    |> Map.fetch!("public_facts")
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  describe "the pack" do
    test "Brenna and Tam send people to the forge and the cottage" do
      pack = Pack.load("tin_valley", "default", ["inn_world"])
      brenna = Enum.join(npc(pack, "innkeep")["hooks"], "\n")
      tam = Enum.join(npc(pack, "stable_lad")["hooks"], "\n")

      assert brenna =~ "Hilde Brask's forge off the Market Square"
      assert brenna =~ "Old Maude's cottage off the Market Square"
      assert tam =~ "runs bread to Maude's cottage and coal to the forge"
      refute brenna =~ "Pip"
    end

    test "with the Tinjacks, Brenna also points at Maude because of Pip" do
      pack = Pack.load("tin_valley", "default", ["inn_world", "antagonist"])
      assert Enum.any?(npc(pack, "innkeep")["hooks"], &(&1 =~ "tell Maude at her cottage"))
    end

    test "without the inn world, Brenna's hooks are as before" do
      hooks = npc(Pack.load("tin_valley", "default", []), "innkeep")["hooks"]
      refute Enum.any?(hooks, &(&1 =~ "forge" or &1 =~ "Maude"))
    end

    test "the rumours are heard at the inn, in the yard and in the square, not at the places themselves" do
      pack = Pack.load("tin_valley", "default", ["inn_world"])

      for place <- ~w(valley_inn inn_yard market_square),
          do: assert(heard_at(pack, place) == @rumours)

      assert heard_at(pack, "smithy") == []
      assert heard_at(pack, "herb_cottage") == []
    end
  end

  describe "sessions" do
    test "with INN_WORLD the first GM turn hears both rumours and Brenna's new hooks" do
      System.put_env("INN_WORLD", "on")
      {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})

      assert {:ok, _} = GameSessions.submit_message(session.id, "I look around the common room.")

      session = Repo.get!(GameSession, session.id)
      ids = Enum.map(session.world_state["public_facts"], & &1["id"])
      assert Enum.all?(@rumours, &(&1 in ids))

      per_turn = session |> Context.build_gm_context() |> Context.per_turn_section()
      assert per_turn =~ "## Perceived facts"
      assert per_turn =~ "Brask's forge off the Market Square rang past midnight"
      assert per_turn =~ "Old Maude, the herb-wife"
      assert NPC.format_gm_sections(session.id, ["innkeep"]) =~ "Hilde Brask's forge"
    end

    test "the baseline variant and sessions without the flag hear no rumours" do
      {:ok, plain} = GameSessions.create_session(%{adventure_id: "tin_valley"})
      System.put_env("INN_WORLD", "on")

      {:ok, baseline} =
        GameSessions.create_session(%{adventure_id: "tin_valley", variant: "baseline"})

      for session <- [plain, baseline] do
        refute NPC.get_instance(session.id, "smith")
        refute NPC.format_gm_sections(session.id, ["innkeep"]) =~ "Hilde Brask"
      end
    end
  end
end
