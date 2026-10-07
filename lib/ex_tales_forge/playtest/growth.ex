defmodule TalesForge.Playtest.Growth do
  @moduledoc """
  How fast the character grew in a playtest run: per skill, the rolls, the
  Learning Points gained and the improvements made (wait/rest rolls and
  training), from the session's turns. The runner stores it on the run's
  `growth` when the run ends, so the Jev baseline shows the growth pace.
  """

  import Ecto.Query

  alias TalesForge.Repo
  alias TalesForge.Schemas.Turn

  @typedoc "Growth of one run: `skills` per skill plus totals."
  @type t :: %{required(String.t()) => term()}

  @doc "Growth for a session, from its turns in order."
  @spec for_session(Ecto.UUID.t()) :: t()
  def for_session(session_id) do
    Turn
    |> where([t], t.game_session_id == ^session_id)
    |> order_by(:turn_number)
    |> select([t], t.mechanical_resolution)
    |> Repo.all()
    |> summarize()
  end

  @doc """
  Growth from a list of turns' `mechanical_resolution` maps.

      iex> TalesForge.Playtest.Growth.summarize([
      ...>   %{"skill" => "stealth", "lp_awarded" => 1.0},
      ...>   %{"skill" => "stealth", "lp_awarded" => 0.5,
      ...>     "improvements" => [%{"skill" => "stealth", "improved" => true}]}
      ...> ])
      %{
        "skills" => %{
          "stealth" => %{"rolls" => 2, "lp_gained" => 1.5, "attempts" => 1, "improvements" => 1}
        },
        "rolls" => 2,
        "lp_gained" => 1.5,
        "attempts" => 1,
        "improvements" => 1
      }
  """
  @spec summarize([map() | nil]) :: t()
  def summarize(resolutions) when is_list(resolutions) do
    skills =
      Enum.reduce(resolutions, %{}, fn res, acc ->
        res = res || %{}
        acc |> add_roll(res) |> add_improvements(res)
      end)

    totals =
      for key <- ~w(rolls lp_gained attempts improvements), into: %{} do
        {key, skills |> Map.values() |> Enum.map(& &1[key]) |> Enum.sum() |> round_lp(key)}
      end

    Map.put(totals, "skills", skills)
  end

  defp add_roll(acc, %{"skill" => skill, "lp_awarded" => lp})
       when is_binary(skill) and is_number(lp) do
    acc
    |> bump(skill, "rolls", 1)
    |> bump(skill, "lp_gained", lp)
  end

  defp add_roll(acc, _res), do: acc

  defp add_improvements(acc, res) do
    res
    |> Map.get("improvements", [])
    |> List.wrap()
    |> Enum.reduce(acc, fn
      %{"skill" => skill} = entry, acc when is_binary(skill) ->
        acc
        |> bump(skill, "attempts", 1)
        |> bump(skill, "improvements", if(entry["improved"] == true, do: 1, else: 0))

      _entry, acc ->
        acc
    end)
  end

  defp bump(acc, skill, key, by) do
    Map.update(acc, skill, Map.put(empty(), key, by), fn s ->
      Map.update!(s, key, &round_lp(&1 + by, key))
    end)
  end

  defp empty, do: %{"rolls" => 0, "lp_gained" => 0.0, "attempts" => 0, "improvements" => 0}

  defp round_lp(value, "lp_gained"), do: Float.round(value * 1.0, 1)
  defp round_lp(value, _key), do: value
end
