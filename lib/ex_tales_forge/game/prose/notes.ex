defmodule TalesForge.Game.Prose.Notes do
  @moduledoc """
  Prose GM prototype (`GM_REPLY_MODE=prose`): GM notes and the running
  situation summary, written every `GM_NOTES_EVERY` turns (default 3) by a
  separate small call instead of by the GM on every turn.

  The call runs asynchronously after the turn is persisted (off the critical
  path), on conv id `<session>:notes`, purpose `gm_notes`. Its input is small:
  the current situation lines plus the last few turns (player action + GM
  prose), not the rules. The result is a player-unaware `gm_notes` session
  event; `apply_latest/2` moves the summary into `world["situation_lines"]` at
  the start of the next prose turn, so it never races a turn's world-state
  write.
  """

  require Logger

  import Ecto.Query

  alias TalesForge.Config
  alias TalesForge.Game.Prose.Events
  alias TalesForge.LLM
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, Turn}

  @kind "gm_notes"

  @system """
  You keep the Game Master's private notes for a text RPG session. You never
  speak to the player. From the current situation and the latest turns, write:

  SUMMARY:
  - up to 3 short bullets: where the character is, open threads, tone (under 250 characters total)
  NOTES: 1-2 terse sentences, under 200 characters: what the GM should remember, withhold or plan next.

  Reply in exactly that format, nothing else. Use only facts stated in the turns.
  """

  @doc "Schedules a notes call when `turn_number` is a multiple of GM_NOTES_EVERY."
  def maybe_schedule(session_id, turn_number) do
    if rem(turn_number, Config.gm_notes_every()) == 0 do
      Task.Supervisor.start_child(TalesForge.Playtest.Supervisor, fn ->
        run(session_id, turn_number)
      end)
    end

    :ok
  end

  @doc "Writes notes + summary for the turns up to `turn_number`."
  def run(session_id, turn_number) do
    with %GameSession{} = session <- Repo.get(GameSession, session_id),
         turns when turns != [] <- recent_turns(session_id, turn_number),
         {:ok, text} <-
           LLM.complete_gm_notes(messages(session.world_state || %{}, turns),
             session_id: session_id,
             turn_number: turn_number
           ),
         %{} = parsed <- parse(text) do
      store(session_id, turn_number, parsed)
      {:ok, parsed}
    else
      nil ->
        {:error, :not_found}

      [] ->
        {:error, :no_turns}

      {:error, reason} = error ->
        Logger.warning("gm notes failed session=#{session_id} reason=#{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.warning("gm notes crashed session=#{session_id} error=#{Exception.message(e)}")
      {:error, :crashed}
  end

  @doc false
  def messages(world, turns) do
    situation =
      case Map.get(world, "situation_lines", []) do
        [] -> "(none)"
        lines -> Enum.join(lines, "\n")
      end

    turn_text =
      Enum.map_join(turns, "\n\n", fn t ->
        "Turn #{t.turn_number}\nPlayer: #{t.player_action}\nGM: #{t.narrative}"
      end)

    user = """
    Location: #{Map.get(world, "location_name", "unknown")}
    Current situation lines:
    #{situation}

    Latest turns:
    #{turn_text}
    """

    [%{role: "system", content: @system}, %{role: "user", content: user}]
  end

  @doc false
  def parse(text) do
    # Models like to bold the tags ("**SUMMARY:**"); drop the markup first.
    text = String.replace(text, "**", "")

    summary =
      case Regex.run(~r/SUMMARY:\s*(.*?)(?:\n\s*NOTES:|\z)/s, text) do
        [_, block] ->
          block
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(String.trim(&1, "-* ") == ""))
          |> Enum.take(3)
          |> Enum.map(&String.slice(&1, 0, 160))

        _ ->
          []
      end

    notes =
      case Regex.run(~r/NOTES:\s*(.+)\z/s, text) do
        [_, n] -> n |> String.trim() |> String.slice(0, 240)
        _ -> nil
      end

    %{"situation_lines" => summary, "gm_notes" => notes}
  end

  @doc """
  Prose mode, start of a turn: applies the newest stored summary that the world
  state has not seen yet.
  """
  def apply_latest(world, session_id) do
    applied = Map.get(world, "notes_applied_turn", 0)

    case latest(session_id) do
      %{"turn_number" => turn, "situation_lines" => [_ | _] = lines} when turn > applied ->
        world
        |> Map.put("situation_lines", lines)
        |> Map.put("notes_applied_turn", turn)

      _ ->
        world
    end
  end

  def latest(session_id), do: Events.latest(session_id, @kind)

  def list_for_session(session_id), do: Events.list(session_id, @kind)

  defp recent_turns(session_id, turn_number) do
    n = Config.gm_notes_every()

    Turn
    |> where([t], t.game_session_id == ^session_id and t.turn_number <= ^turn_number)
    |> order_by([t], desc: t.turn_number)
    |> limit(^n)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp store(session_id, turn_number, parsed) do
    Events.insert(session_id, @kind, "gm", Map.put(parsed, "turn_number", turn_number))
  end
end
