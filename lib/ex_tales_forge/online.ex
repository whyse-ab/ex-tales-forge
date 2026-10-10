defmodule TalesForge.Online do
  @moduledoc """
  Who is online right now, for "Online now" on `/team` (board card "Who's
  online right now", decision 2026-10-10).

  - **Founders** are tracked with Phoenix Presence (`TalesForgeWeb.Presence`)
    on the PubSub this app already runs. `TalesForgeWeb.LiveAuth` calls
    `track/2` when a signed-in LiveView connects, so every admin and team page
    counts, with the page name from `page_label/1`. Presence removes the entry
    when the page closes.
  - **Both apps, one list.** Production and playtest are separate Fly apps
    that do not share PubSub. Production reads playtest's founders from
    playtest's `GET /internal/online` (`TalesForgeWeb.OnlinePeerController`,
    shared `COSTS_PEER_TOKEN`), the same pull model as the costs page. The
    reader is `TalesForge.Online.Peer`, which keeps the last answer for
    `TalesForge.Online.Peer.ttl_ms/0`; an older answer counts as empty.
  - **Bots** do not keep a page open. `bot_seen/1` notes each authorised call to
    the board API (`TalesForgeWeb.BoardApiController`); the team page adds the
    bots' other activity (`TalesForge.TeamOnline`).
  """

  alias TalesForge.AppRole
  alias TalesForge.Online.Peer
  alias TalesForgeWeb.Presence

  @topic "online"
  @changed_topic "online:changed"

  @typedoc "One founder on one app."
  @type founder :: %{
          email: String.t(),
          page: String.t(),
          app: String.t(),
          since: DateTime.t()
        }

  # Module names as strings, so this shared module does not depend on the
  # admin LiveViews (`mix deploy.check_boundaries`).
  @pages %{
    "TalesForgeWeb.TeamLive" => "Team page",
    "TalesForgeWeb.TeamPresentationLive" => "Presentation",
    "TalesForgeWeb.HomeLive" => "Game",
    "TalesForgeWeb.CreateCharacterLive" => "Game",
    "TalesForgeWeb.PlayLive" => "Game",
    "TalesForgeWeb.AdminLive.DashboardLive" => "Admin",
    "TalesForgeWeb.AdminLive.SessionLive.Index" => "Sessions",
    "TalesForgeWeb.AdminLive.SessionLive.Show" => "Sessions",
    "TalesForgeWeb.AdminLive.NpcLive.Index" => "NPCs",
    "TalesForgeWeb.AdminLive.NpcLive.Show" => "NPCs",
    "TalesForgeWeb.AdminLive.TurnLive.Index" => "Turns",
    "TalesForgeWeb.AdminLive.CostsLive" => "Costs",
    "TalesForgeWeb.AdminLive.NpcDefinitionLive.Index" => "NPC definitions",
    "TalesForgeWeb.AdminLive.NpcDefinitionLive.Show" => "NPC definitions",
    "TalesForgeWeb.AdminLive.PlaytestLive.Index" => "Playtest runs",
    "TalesForgeWeb.AdminLive.PlaytestLive.Show" => "Playtest runs",
    "TalesForgeWeb.AdminLive.DecisionLive.Index" => "Decisions",
    "TalesForgeWeb.AdminLive.DecisionLive.Show" => "Decisions",
    "TalesForgeWeb.AdminLive.DocLive.Index" => "Docs",
    "TalesForgeWeb.AdminLive.SurveyLive.Show" => "Survey",
    "TalesForgeWeb.AdminLive.SurveyLive.Index" => "Surveys",
    "TalesForgeWeb.AdminLive.SurveyLive.Results" => "Survey results",
    "Phoenix.LiveDashboard.PageLive" => "Telemetry"
  }

  @doc """
  The page name shown for a LiveView module; "Admin" for a module not in the
  list.

      iex> TalesForge.Online.page_label(TalesForgeWeb.TeamLive)
      "Team page"
      iex> TalesForge.Online.page_label(SomeNewLive)
      "Admin"
  """
  @spec page_label(module()) :: String.t()
  def page_label(view) when is_atom(view),
    do: Map.get(@pages, view |> Atom.to_string() |> String.replace_prefix("Elixir.", ""), "Admin")

  def page_label(_view), do: "Admin"

  @doc "The Presence topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Subscribes the caller to changes: Presence diffs on this app
  (`%Phoenix.Socket.Broadcast{event: "presence_diff"}`) and `{:online, :changed}`
  when the other app's list changes.
  """
  @spec subscribe() :: :ok
  def subscribe do
    :ok = Phoenix.PubSub.subscribe(TalesForge.PubSub, @topic)
    Phoenix.PubSub.subscribe(TalesForge.PubSub, @changed_topic)
  end

  @doc false
  @spec broadcast_changed() :: :ok
  def broadcast_changed,
    do: Phoenix.PubSub.broadcast(TalesForge.PubSub, @changed_topic, {:online, :changed})

  @doc """
  Tracks the LiveView process of `socket` for the founder `email`, once it is
  connected. Nested LiveViews are not tracked (their parent page is).
  Never raises: Presence is a nice-to-have, never a reason to fail a mount.
  """
  @spec track(Phoenix.LiveView.Socket.t(), String.t()) :: :ok
  def track(%Phoenix.LiveView.Socket{} = socket, email) when is_binary(email) do
    if Phoenix.LiveView.connected?(socket) and is_nil(socket.parent_pid) do
      meta = %{
        page: page_label(socket.view),
        app: Atom.to_string(AppRole.role()),
        since: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      _ = Presence.track(self(), @topic, String.downcase(email), meta)
    end

    :ok
  rescue
    _ -> :ok
  end

  def track(_socket, _email), do: :ok

  @doc """
  The founders online on this app, one entry per founder (their newest page),
  as plain maps with string keys (the JSON shape of `/internal/online`).
  """
  @spec local() :: [map()]
  def local do
    @topic
    |> Presence.list()
    |> Enum.map(fn {email, %{metas: metas}} ->
      meta = Enum.max_by(metas, &(&1[:since] || ""))
      %{"email" => email, "page" => meta[:page], "app" => meta[:app], "since" => meta[:since]}
    end)
  end

  @doc """
  Validates entries from the other app (or from `local/0`) into `t:founder/0`.
  Entries with a missing field are left out.

      iex> TalesForge.Online.normalize([%{"email" => "a@x.se", "page" => "Docs",
      ...>   "app" => "playtest", "since" => "2026-10-10T12:00:00Z"}, %{"email" => 1}])
      [%{email: "a@x.se", page: "Docs", app: "playtest", since: ~U[2026-10-10 12:00:00Z]}]
  """
  @spec normalize(term()) :: [founder()]
  def normalize(list) when is_list(list), do: Enum.flat_map(list, &entry/1)
  def normalize(_), do: []

  defp entry(%{"email" => e, "page" => p, "app" => a, "since" => s})
       when is_binary(e) and is_binary(p) and is_binary(a) and is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, since, _} -> [%{email: e, page: p, app: a, since: since}]
      _ -> []
    end
  end

  defp entry(_), do: []

  @doc """
  Every founder online on both apps: this app's Presence plus the other app's
  last answer while it is fresh (`TalesForge.Online.Peer`). A founder with a
  page open on each app is listed once per app. Sorted by email.
  """
  @spec founders() :: [founder()]
  def founders do
    (normalize(local()) ++ Peer.founders())
    |> Enum.uniq_by(&{&1.email, &1.app})
    |> Enum.sort_by(&{&1.email, &1.app})
  end

  @doc "Notes that `bot` (`:case`, `:bobby`, `:gentry`) made a board API call now."
  @spec bot_seen(atom()) :: :ok
  def bot_seen(bot) when is_atom(bot), do: Peer.bot_seen(bot, DateTime.utc_now())

  @doc "The time of each bot's latest board API call since this app started."
  @spec bot_calls() :: %{optional(atom()) => DateTime.t()}
  def bot_calls, do: Peer.bot_calls()
end
