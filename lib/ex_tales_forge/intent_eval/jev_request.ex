defmodule TalesForge.IntentEval.JevRequest do
  @moduledoc """
  Builds the Jev request the eval reader posts: candidates, state and
  questions, honouring `t:TalesForge.IntentEval.JevOpts.t/0`.

  With default switches this is the same request as `JevIntent.state/2`,
  `JevIntent.questions/1` and `JevSelfCheck.ask/1`. The live path does not
  call this module.
  """

  alias TalesForge.Game.{JevIntent, JevSelfCheck}
  alias TalesForge.IntentEval.JevOpts

  @narration_chars 800
  @player_chars 600

  @doc """
  The Jev request for an eval item: candidates, state and questions.
  """
  @spec request(map(), String.t(), JevOpts.t() | keyword()) :: %{
          candidates: [JevIntent.candidate()],
          state: map(),
          questions: keyword()
        }
  def request(context, text, switches \\ %JevOpts{})

  def request(context, text, jev_opts) when is_list(jev_opts) do
    request(context, text, switches(jev_opts))
  end

  def request(context, text, %JevOpts{} = switches) do
    candidates = JevIntent.candidates(context)

    questions =
      candidates
      |> JevIntent.questions(JevIntent.catalogue(), switches.skill_split)
      |> JevSelfCheck.ask()

    %{candidates: candidates, state: state(context, text, switches), questions: questions}
  end

  @doc """
  The cache key of a Jev request: the hex SHA-256 of its content (`model`,
  `state`, `questions`) in a canonical form, with every map's keys sorted.
  """
  @spec request_key(map(), keyword(), String.t() | nil) :: String.t()
  def request_key(state, questions, model) do
    %{model: model, state: state, questions: Jev.questions(questions)}
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec cached_post(%{state: map(), questions: keyword()}, keyword(), String.t() | nil) ::
          {:ok, map(), boolean()} | {:error, term()}
  def cached_post(%{state: state, questions: questions}, post_opts, nil) do
    with {:ok, reply} <- Jev.HTTP.post(state, questions, post_opts), do: {:ok, reply, false}
  end

  def cached_post(%{state: state, questions: questions}, post_opts, dir) do
    path = Path.join(dir, request_key(state, questions, post_opts[:model]) <> ".etf")

    case File.read(path) do
      {:ok, binary} ->
        {:ok, :erlang.binary_to_term(binary), true}

      {:error, _} ->
        with {:ok, reply} <- Jev.HTTP.post(state, questions, post_opts) do
          File.mkdir_p!(dir)
          File.write!(path, :erlang.term_to_binary(reply))
          {:ok, reply, false}
        end
    end
  end

  def switches(jev_opts) do
    case Keyword.get(jev_opts, :switches) do
      %JevOpts{} = switches -> switches
      _other -> %JevOpts{}
    end
  end

  defp state(context, text, switches) do
    JevIntent.state(context, text)
    |> Map.put("last_narration", narration(context, switches.narration_chars))
    |> Map.put("player_text", player_text(text, switches.player_chars))
    |> put_last_actions(context, switches.last_actions)
  end

  defp narration(context, chars) do
    chars = chars || @narration_chars

    case Map.get(context, "last_narration") do
      text when is_binary(text) -> String.slice(text, -chars, chars)
      _ -> ""
    end
  end

  defp player_text(text, chars) do
    text |> to_string() |> String.trim() |> String.slice(0, chars || @player_chars)
  end

  defp put_last_actions(state, _context, false), do: state

  defp put_last_actions(state, context, true) do
    Map.put(state, "last_player_actions", last_player_actions(context))
  end

  defp last_player_actions(context) do
    context
    |> Map.get("recent_turns", [])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"action" => action} when is_binary(action) and action != "" -> [action]
      _ -> []
    end)
    |> Enum.take(-3)
  end

  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(atom) when is_atom(atom) and atom not in [nil, true, false], do: to_string(atom)
  defp canonical(other), do: other
end
