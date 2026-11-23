defmodule TalesForge.IntentEval.JevOpts do
  @moduledoc """
  Eval-only switches for the Jev reader (`mix intent.eval` / `IntentEval.run/1`).

  They live in `opts[:jev][:switches]`. Request-switch defaults reproduce
  today's Jev request. `clarify_v2` and `runner_up` select the clarify
  band set used when scoring; the live path reads `JEV_CLARIFY_V2` from
  `TalesForge.Config`, not this struct.
  """

  @narration_chars 800
  @player_chars 600

  defstruct skill_split: false,
            narration_chars: @narration_chars,
            player_chars: @player_chars,
            last_actions: false,
            clarify_v2: false,
            runner_up: nil

  @typedoc "Eval Jev request and band switches."
  @type t :: %__MODULE__{
          skill_split: boolean(),
          narration_chars: pos_integer(),
          player_chars: pos_integer(),
          last_actions: boolean(),
          clarify_v2: boolean(),
          runner_up: float() | nil
        }

  @doc """
  Builds the switches from `mix intent.eval` flags, falling back to env vars.

  Flags win when set. Otherwise `SKILL_SPLIT`, `JEV_NARRATION_CHARS`,
  `JEV_PLAYER_CHARS`, `JEV_LAST_ACTIONS` and `JEV_CLARIFY_V2` are read.
  Booleans follow `TalesForge.Config`: `on`, `true` and `1` are true.
  Missing values are today's defaults (split, last-actions and clarify
  v2 off, 800 / 600 chars, no runner-up override).

  `getenv` defaults to `System.get_env/1`; tests pass their own.
  """
  @spec from_flags(keyword(), (String.t() -> String.t() | nil)) :: t()
  def from_flags(opts, getenv \\ &System.get_env/1) do
    %__MODULE__{
      skill_split: bool(opts[:skill_split], getenv.("SKILL_SPLIT")),
      narration_chars:
        int(opts[:narration_chars], getenv.("JEV_NARRATION_CHARS"), @narration_chars),
      player_chars: int(opts[:player_chars], getenv.("JEV_PLAYER_CHARS"), @player_chars),
      last_actions: bool(opts[:last_actions], getenv.("JEV_LAST_ACTIONS")),
      clarify_v2: bool(opts[:clarify_v2], getenv.("JEV_CLARIFY_V2")),
      runner_up: number(opts[:runner_up])
    }
  end

  @doc "The clarify band set selected by `opts` (`:v2` when `clarify_v2` is on)."
  @spec band_version(keyword() | t()) :: :v1 | :v2
  def band_version(%__MODULE__{clarify_v2: true}), do: :v2
  def band_version(%__MODULE__{}), do: :v1

  def band_version(opts) when is_list(opts) do
    switches = Keyword.get(Keyword.get(opts, :jev, []), :switches)

    if opts[:clarify_v2] == true or match?(%__MODULE__{clarify_v2: true}, switches),
      do: :v2,
      else: :v1
  end

  defp bool(flag, _env) when is_boolean(flag), do: flag

  defp bool(nil, env), do: env in ~w(on true 1)

  defp int(n, _env, _default) when is_integer(n) and n > 0, do: n
  defp int(nil, env, default) when env in [nil, ""], do: default

  defp int(nil, env, _default) when is_binary(env) do
    case Integer.parse(String.trim(env)) do
      {n, ""} when n > 0 ->
        n

      _ ->
        raise ArgumentError, "expected a positive integer, got: #{inspect(env)}"
    end
  end

  defp number(n) when is_number(n) and n >= 0, do: n / 1
  defp number(nil), do: nil
end
