defmodule TalesForgeWeb.TeamPrFeedLive do
  @moduledoc """
  The live PR feed on `/team`, nested in `TalesForgeWeb.TeamLive` with
  `live_render/3` so its updates patch only this part of the page (the
  page's own animation state stays untouched).

  On mount it shows `TalesForge.PrFeed.snapshot/0`; once connected it
  subscribes to the feed's PubSub topic and re-renders on every
  `{:pr_feed, snapshot}` from `TalesForge.PrFeed.Poller`. Pull requests that
  are new, or changed state, since the previous snapshot are marked fresh for
  that render (`TalesForgeWeb.TeamPrFeed`). No events, no GitHub calls from
  here or from the browser. Sign-in as for every LiveView
  (`TalesForgeWeb.LiveAuth`).
  """

  use TalesForgeWeb, :live_view

  alias TalesForge.PrFeed
  alias TalesForgeWeb.TeamPrFeed

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: PrFeed.subscribe()
    snapshot = PrFeed.snapshot()

    {:ok,
     socket
     |> assign(feed: snapshot, fresh: MapSet.new(), now: DateTime.utc_now())
     |> assign(:seen, keys(snapshot))}
  end

  @impl true
  def handle_info({:pr_feed, snapshot}, socket) do
    {:noreply,
     assign(socket,
       feed: snapshot,
       fresh: fresh(snapshot, socket.assigns.seen),
       seen: keys(snapshot),
       now: DateTime.utc_now()
     )}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <TeamPrFeed.feed feed={@feed} fresh={@fresh} now={@now} />
    """
  end

  @doc """
  The numbers of the pull requests in `snapshot` that are new, or in a new
  state, compared with `seen` (the `{number, state}` pairs shown before). An
  empty `seen` (first data) marks nothing, so the page doesn't animate on load.
  """
  @spec fresh(PrFeed.snapshot(), MapSet.t()) :: MapSet.t()
  def fresh(snapshot, seen) do
    if MapSet.size(seen) == 0 do
      MapSet.new()
    else
      for item <- snapshot.items, {item.number, item.state} not in seen, into: MapSet.new() do
        item.number
      end
    end
  end

  defp keys(snapshot), do: MapSet.new(snapshot.items, &{&1.number, &1.state})
end
