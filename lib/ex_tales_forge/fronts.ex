defmodule TalesForge.Fronts do
  @moduledoc """
  Ecto persistence for session fronts. Play-loop only.

  `seed_session/1` is a no-op for Crossroads (zero fronts). tin_valley copies
  pack JSON into `FrontInstance.definition` and mutable clocks into `runtime_state`.
  """

  import Ecto.Query

  alias TalesForge.Game.Features
  alias TalesForge.Game.Pack
  alias TalesForge.Game.Variant
  alias TalesForge.Game.WorldClock
  alias TalesForge.Repo
  alias TalesForge.Schemas.{FrontInstance, GameSession}

  def seed_session(%GameSession{} = session) do
    case Map.get(session.world_state || %{}, "adventure_id") do
      "tin_valley" -> seed_from_pack(session, pack_fronts(session.world_state || %{}))
      _ -> :ok
    end
  end

  def seed_session(_), do: :ok

  defp pack_fronts(world) do
    Pack.load("tin_valley", Variant.of(world), Features.of(world)).fronts
  end

  def list_all(session_id) when is_binary(session_id) do
    FrontInstance
    |> where([f], f.game_session_id == ^session_id)
    |> order_by([f], f.front_id)
    |> Repo.all()
  end

  def get_instance(session_id, front_id)
      when is_binary(session_id) and is_binary(front_id) do
    Repo.get_by(FrontInstance, game_session_id: session_id, front_id: front_id)
  end

  def sim_fronts(session_id) when is_binary(session_id) do
    Enum.map(list_all(session_id), &to_sim/1)
  end

  def persist_tick_multi(multi, session_id, sim) when is_map(sim) do
    Enum.reduce(sim.fronts, multi, fn front, acc ->
      inst = get_instance(session_id, front_id(front))

      if inst do
        cs =
          FrontInstance.changeset(inst, %{
            runtime_state: runtime(front),
            status: status(front)
          })

        Ecto.Multi.update(acc, {:front, inst.front_id}, cs)
      else
        acc
      end
    end)
  end

  defp to_sim(%FrontInstance{} = inst) do
    %{
      front_id: inst.front_id,
      status: inst.status,
      definition: inst.definition,
      runtime_state: inst.runtime_state
    }
  end

  defp front_id(%{front_id: id}), do: id
  defp runtime(%{runtime_state: state}), do: state
  defp status(%{status: status}), do: status

  defp seed_from_pack(%GameSession{id: session_id, world_state: world}, fronts) do
    world_tick = Map.get(world, "world_tick", WorldClock.default_start_tick())

    Enum.each(fronts, fn defn ->
      front_id = defn["id"]

      runtime = %{
        "clocks" => defn["clocks"] || %{},
        "resources" => defn["resources"] || %{},
        "beliefs" => defn["beliefs"] || %{},
        "memories" => [],
        "public_facts" => defn["public_facts"] || [],
        "since_tick" => world_tick
      }

      %FrontInstance{}
      |> FrontInstance.changeset(%{
        game_session_id: session_id,
        front_id: front_id,
        status: defn["status"] || "live",
        definition: defn,
        runtime_state: runtime
      })
      |> Repo.insert!(
        on_conflict: :nothing,
        conflict_target: [:game_session_id, :front_id]
      )
    end)

    :ok
  end
end
