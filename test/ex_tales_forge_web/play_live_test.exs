defmodule TalesForgeWeb.PlayLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, Turn}

  setup %{conn: conn} do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  test "play surface hides skill, roll, outcome, and LP", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Living Tin Valley", adventure_id: "tin_valley"})

    {:ok, _view, html} = live(conn, ~p"/play/#{session.id}")

    assert html =~ "Time"
    assert html =~ "Location"
    assert html =~ "wounds"
    assert html =~ "Coins"
    assert html =~ "Inventory"
    assert html =~ "Brenna"
    refute html =~ "fee_copper"

    refute_sheet(html)

    assert {:ok, %{status: :processing}} =
             GameSessions.submit_message(session.id, "study the inn")

    turn =
      Turn
      |> Repo.all()
      |> Enum.find(&(&1.game_session_id == session.id))

    assert is_integer(turn.mechanical_resolution["roll"])
    assert turn.mechanical_resolution["outcome"] in ["success", "partial_success", "failure"]

    {:ok, _view, html} = live(conn, ~p"/play/#{session.id}")
    refute_sheet(html)
  end

  test "dead session disables play input", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Dead Elara", adventure_id: "tin_valley"})

    world = put_in(session.world_state, ["character", "vitality"], "dead")

    session
    |> GameSession.changeset(%{status: "dead", world_state: world})
    |> Repo.update!()

    {:ok, view, html} = live(conn, ~p"/play/#{session.id}")

    assert html =~ "You are dead."
    assert html =~ "dead"
    assert has_element?(view, "input[name=message][disabled]")
    assert has_element?(view, "button[type=submit][disabled]")
  end

  test "re-rendering mid-turn keeps the GM placeholder out of the stream", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Thinking Tin Valley", adventure_id: "tin_valley"})

    {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")

    send(view.pid, {:turn_processing, %{}})
    assert render(view) =~ "The GM is thinking…"

    # A stream insert while the placeholder is showing used to raise
    # "setting phx-update to \"stream\" requires setting an ID on each child".
    send(
      view.pid,
      {:npc_initiative,
       %{npc_id: "brenna", npc_name: "Brenna", world_tick: 1, text: "Brenna waves."}}
    )

    html = render(view)
    assert html =~ "Brenna waves."
    assert html =~ "The GM is thinking…"
    refute has_element?(view, "#narrative-log > p")

    send(view.pid, {:turn_failed, "boom"})
    refute render(view) =~ "The GM is thinking…"
  end

  test "a spend cap shows a calm message, not a failure", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Capped Tin Valley", adventure_id: "tin_valley"})

    {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")

    send(view.pid, {:turn_processing, %{}})
    send(view.pid, {:turn_failed, {:spend_cap, :day}})

    html = render(view)
    assert html =~ "resting until tomorrow"
    refute html =~ "Turn failed"
    refute html =~ "The GM is thinking…"
  end

  # Checks rendered text only. Matching raw HTML also hits attributes, and the
  # random data-phx-session / csrf tokens occasionally contain e.g. "XP".
  defp refute_sheet(html) do
    text = visible_text(html)
    # Guard against an empty extraction making every refute pass.
    assert text =~ "Location"

    refute text =~ "Skill:"
    refute text =~ "Outcome:"
    refute text =~ "Roll:"
    refute text =~ "+LP"
    refute text =~ "Learning points"
    refute text =~ "insight +2"
    refute text =~ "you learned"
    refute text =~ ~r/\bXP\b/
    refute text =~ "learning_failures"
  end

  defp visible_text(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("body")
    |> LazyHTML.to_tree()
    |> LazyHTML.Tree.postwalk(fn
      {tag, _attrs, _children} when tag in ["script", "style", "template"] -> []
      node -> node
    end)
    |> LazyHTML.from_tree()
    |> LazyHTML.text(separator: " ")
  end
end
