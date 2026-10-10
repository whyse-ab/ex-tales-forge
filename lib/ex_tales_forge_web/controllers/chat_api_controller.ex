defmodule TalesForgeWeb.ChatApiController do
  @moduledoc """
  The bots' API for the team chat: `GET /internal/chat` (the latest
  messages) and `POST /internal/chat` (`{"body": "..."}`, post as the bot).

  - Production only, like the board (`TalesForge.AppRole.here?(:board)`);
    elsewhere 404. Off (404) while config `:team_chat` names no loaded module.
  - The same bearer token per bot as the board API
    (`TalesForge.BoardApi.bot_for_token/1`); missing or unknown: 401.
  - The implementation is the module in config `:team_chat`
    (`TalesForge.Chat.api/3`), so this shared controller does not depend on
    admin code.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AppRole
  alias TalesForge.BoardApi
  alias TalesForge.Online
  alias TalesForgeWeb.PeerToken

  @doc "The latest messages, for an authorised bot."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params), do: dispatch(conn, :index, params)

  @doc "Posts a message as an authorised bot."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params), do: dispatch(conn, :create, params)

  defp dispatch(conn, action, params) do
    with true <- AppRole.here?(:board),
         mod when not is_nil(mod) <- impl() do
      case conn |> bearer() |> BoardApi.bot_for_token() do
        nil ->
          PeerToken.unauthorized(conn)

        bot ->
          :ok = Online.bot_seen(bot)
          {status, body} = mod.api(action, bot, params)

          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_status(status)
          |> json(body)
      end
    else
      _ -> PeerToken.not_found(conn)
    end
  end

  defp impl do
    case Application.get_env(:ex_tales_forge, :team_chat) do
      mod when is_atom(mod) and not is_nil(mod) ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :api, 3), do: mod

      _ ->
        nil
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end
end
