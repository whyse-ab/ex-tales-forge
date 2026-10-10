defmodule TalesForge.TeamOnline do
  @moduledoc """
  The data of the "who is online" counter in the admin and /team header
  (`TalesForgeWeb.OnlineHeaderLive`, board card "Who's online right now"):

  - **Founders**: everyone with a page open on production or playtest right
    now (`TalesForge.Online.people/1`, Phoenix Presence plus playtest's
    list), one entry per person with each page and app once.
  - **Bots** (Case, Bobby, Gentry) do not keep a page open. Each shows their
    latest activity and when it was: a board API call (each wake-up reads the
    board), a comment, a card move or a link on the board, and for Bobby the
    latest pull request in the live PR feed (Bobby writes the pull requests).
    A bot counts as online when that was less than `online_minutes/0` ago.
  """

  import Ecto.Query

  alias TalesForge.AppRole
  alias TalesForge.Board.Mentions
  alias TalesForge.Board.{Comment, Link, Transition}
  alias TalesForge.Online
  alias TalesForge.PrFeed
  alias TalesForge.Repo
  alias TalesForge.TeamPage

  @bots [{:case, "Case"}, {:bobby, "Bobby"}, {:gentry, "Gentry"}]
  @online_minutes 10

  @typedoc "A founder as shown: `TalesForge.Online.person/0` plus the display name and @handle."
  @type founder :: %{
          key: String.t(),
          name: String.t(),
          handle: String.t() | nil,
          email: String.t(),
          login: String.t() | nil,
          locations: [String.t()],
          since: DateTime.t()
        }

  @typedoc "A bot as shown; `at` and `doing` are nil when nothing was seen yet."
  @type bot :: %{
          id: String.t(),
          name: String.t(),
          at: DateTime.t() | nil,
          doing: String.t() | nil,
          online: boolean()
        }

  @typedoc "Everything the section shows."
  @type t :: %{founders: [founder()], bots: [bot()]}

  @doc "A bot is online when its latest activity is this many minutes old or less."
  @spec online_minutes() :: pos_integer()
  def online_minutes, do: @online_minutes

  @doc "Founders and bots now."
  @spec snapshot(DateTime.t()) :: t()
  def snapshot(now \\ DateTime.utc_now()) do
    %{
      founders:
        Enum.map(Online.people(), fn p ->
          Map.merge(p, %{name: name(p.email, p.login), handle: Mentions.handle_for(p.login)})
        end),
      bots: bots(activity(), now)
    }
  end

  @doc """
  Each bot with its newest activity from `events` (`{bot, at, doing}` tuples),
  and whether that is recent enough to count as online.

      iex> now = ~U[2026-10-10 12:00:00Z]
      iex> [c, b, g] = TalesForge.TeamOnline.bots([{:case, ~U[2026-10-10 11:55:00Z], "Read the board"},
      ...>   {:case, ~U[2026-10-10 10:00:00Z], "Commented on a card"},
      ...>   {:bobby, ~U[2026-10-10 09:00:00Z], "Pull request #7"}], now)
      iex> {c.doing, c.online, b.online, g.at}
      {"Read the board", true, false, nil}
  """
  @spec bots([{atom(), DateTime.t(), String.t()}], DateTime.t()) :: [bot()]
  def bots(events, %DateTime{} = now) do
    for {id, name} <- @bots do
      latest =
        events
        |> Enum.filter(&(elem(&1, 0) == id and match?(%DateTime{}, elem(&1, 1))))
        |> Enum.max_by(&DateTime.to_unix(elem(&1, 1), :microsecond), fn -> nil end)

      case latest do
        {_, at, doing} ->
          %{
            id: Atom.to_string(id),
            name: name,
            at: at,
            doing: doing,
            online: DateTime.diff(now, at, :second) <= @online_minutes * 60
          }

        nil ->
          %{id: Atom.to_string(id), name: name, at: nil, doing: nil, online: false}
      end
    end
  end

  @doc """
  A founder's display name from the team data (accents kept). First the
  handle of their GitHub login (`TalesForge.Board.Mentions`, config
  `:board_founder_handles`), so "Hawkan-Fredriksson" is "Håkan"; then the
  first part of the email; else that first part, capitalised.

      iex> TalesForge.TeamOnline.name("hawkan.fredriksson@gmail.com", "Hawkan-Fredriksson")
      "Håkan"
      iex> TalesForge.TeamOnline.name("fredrik@whyse.se")
      "Fredrik"
      iex> TalesForge.TeamOnline.name("hakan.x@whyse.se", "unknown-login")
      "Håkan"
      iex> TalesForge.TeamOnline.name("sam@example.com")
      "Sam"
  """
  @spec name(String.t(), String.t() | nil) :: String.t()
  def name(email, login \\ nil) do
    first = email |> String.split(["@", ".", "+"]) |> hd() |> String.downcase()
    handle = Mentions.handle_for(login) || plain(first)

    Enum.find(founder_names(), &(plain(&1) == handle)) ||
      Enum.find(founder_names(), String.capitalize(first), &(plain(&1) == plain(first)))
  end

  defp founder_names do
    TeamPage.data()
    |> TeamPage.members()
    |> Enum.find_value([], fn m -> m["kind"] == "humans" && get_in(m, ["people", "names"]) end)
    |> List.wrap()
  end

  defp plain(name) do
    name
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^a-z]/u, "")
  end

  # Every bot activity we know of, as {bot, at, doing}.
  defp activity do
    calls = for {bot, at} <- Online.bot_calls(), do: {bot, at, "Read the board"}
    calls ++ board_activity() ++ pr_activity()
  end

  defp board_activity do
    if AppRole.here?(:board) do
      latest(Comment, :author, "Commented on a card") ++
        latest(Transition, :actor, "Moved a card") ++
        latest(Link, :added_by, "Linked a card")
    else
      []
    end
  rescue
    _ -> []
  end

  defp latest(schema, field, doing) do
    from(r in schema,
      where: like(field(r, ^field), "bot:%"),
      group_by: field(r, ^field),
      select: {field(r, ^field), max(r.inserted_at)}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {"bot:" <> bot, at} ->
      case Enum.find(@bots, fn {id, _} -> Atom.to_string(id) == bot end) do
        {id, _} -> [{id, to_utc(at), doing}]
        nil -> []
      end
    end)
  end

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # Bobby writes the pull requests: the newest one in the feed.
  defp pr_activity do
    case PrFeed.snapshot() do
      %{items: [_ | _] = items} ->
        items
        |> Enum.filter(&match?(%DateTime{}, &1.at))
        |> Enum.map(fn i -> {:bobby, i.at, "Pull request ##{i.number}"} end)

      _ ->
        []
    end
  rescue
    _ -> []
  end
end
