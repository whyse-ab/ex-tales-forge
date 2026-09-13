defmodule TalesForgeWeb.PlayLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.Turn

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
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
    refute html =~ "Skill:"
    refute html =~ "Outcome:"
    refute html =~ "Roll:"
    refute html =~ "+LP"
  end

  defp refute_sheet(html) do
    refute html =~ "Skill:"
    refute html =~ "Outcome:"
    refute html =~ "Roll:"
    refute html =~ "+LP"
    refute html =~ "Learning points"
    refute html =~ "insight +2"
    refute html =~ "you learned"
    refute html =~ "XP"
    refute html =~ "learning_failures"
  end
end
