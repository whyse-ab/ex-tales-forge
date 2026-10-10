defmodule TalesForge.BoardApi do
  @moduledoc """
  The contract between the bots' board API (`TalesForgeWeb.BoardApiController`,
  shared code behind `/internal/board/*`) and the founders' idea board (admin
  code, `TalesForge.Board.Api`), so the shared controller never depends on an
  admin module at compile time (`mix deploy.check_boundaries`).

  The implementing module is config `:ex_tales_forge, :board_api`. `impl/0`
  returns it only when it is loaded; otherwise the API is off (404).

  Bots are `:case`, `:bobby` and `:gentry`. Each has its own bearer token,
  config `:ex_tales_forge, :board_bots` (`BOARD_BOT_TOKEN_<BOT>`), read by
  `bot_for_token/1`.
  """

  @typedoc "A bot that may call the board API."
  @type bot :: :case | :bobby | :gentry

  @typedoc "An API action, one per route."
  @type action :: :index | :show | :refine | :move | :link | :comment

  @typedoc "The HTTP status and JSON body of an answer."
  @type answer :: {pos_integer(), map() | [map()]}

  @doc "Handles one API call by `bot` with the request `params` (path and body merged)."
  @callback handle(action(), bot(), map()) :: answer()

  @bots [:case, :bobby, :gentry]

  @doc "The bots, in order."
  @spec bots() :: [bot()]
  def bots, do: @bots

  @doc "The board module when it is configured and loaded, else nil."
  @spec impl() :: module() | nil
  def impl do
    case Application.get_env(:ex_tales_forge, :board_api) do
      mod when is_atom(mod) and not is_nil(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :handle, 3), do: mod

      _ ->
        nil
    end
  end

  @doc """
  The bot whose `BOARD_BOT_TOKEN_<BOT>` equals `token` (constant-time compare),
  or nil. Bots without a token never match.
  """
  @spec bot_for_token(String.t() | nil) :: bot() | nil
  def bot_for_token(token) do
    case trimmed(token) do
      nil ->
        nil

      token ->
        given = :crypto.hash(:sha256, token)

        Enum.find(@bots, &token_matches?(&1, given))
    end
  end

  defp token_matches?(bot, given) do
    case trimmed(bot_config(bot)[:api_token]) do
      nil -> false
      expected -> Plug.Crypto.secure_compare(given, :crypto.hash(:sha256, expected))
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp trimmed(_value), do: nil

  @doc "One bot's settings from config `:board_bots` (`webhook_url`, `webhook_key`, `api_token`)."
  @spec bot_config(bot()) :: keyword()
  def bot_config(bot) do
    Application.get_env(:ex_tales_forge, :board_bots, []) |> Keyword.get(bot, [])
  end
end
