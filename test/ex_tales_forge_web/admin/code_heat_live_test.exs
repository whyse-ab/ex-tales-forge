defmodule TalesForgeWeb.AdminLive.CodeHeatLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.CodeHeat
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall
  alias TalesForgeWeb.AdminLive.CodeHeatLive

  setup %{conn: conn} do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, CodeHeat)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  defp seed do
    now = DateTime.utc_now()

    {:ok, _} =
      CodeHeat.save(
        %{
          {TalesForge.IntentJev, :read, 2} => {40, 2_500_000},
          {TalesForge.AppRole, :role, 1} => {90_000, 45_000},
          {TalesForge.AppRole, :playtest?, 1} => {1_200_000, 30_000}
        },
        DateTime.add(now, -24, :hour),
        now,
        3
      )
  end

  test "admin only" do
    for conn <- [build_conn(), log_in_non_member(build_conn())] do
      assert redirected_to(get(conn, ~p"/admin/operate/code-heat")) =~ "/admin/login"
    end
  end

  test "in the Operate nav; no sample yet; off on this app", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/operate/code-heat")

    assert has_element?(
             view,
             ~s(#admin-nav a[href="/admin/operate/code-heat"][aria-current="page"])
           )

    assert has_element?(view, "#code-heat-empty")
    assert has_element?(view, "#code-heat-off", "CODE_HEAT_MAP=on")
    assert html =~ "0 AI calls in the last 24 hours"
    refute html =~ "$"
  end

  test "says off on production", %{conn: conn} do
    Application.put_env(:ex_tales_forge, CodeHeat, enabled: true)
    Application.put_env(:ex_tales_forge, :app_name, "tales-forge")
    {:ok, view, _html} = live(conn, ~p"/admin/operate/code-heat")
    assert has_element?(view, "#code-heat-off", "off on production")
  end

  test "shows the heat map with filters, hot spots and AI calls without money", %{conn: conn} do
    Application.put_env(:ex_tales_forge, CodeHeat, enabled: true)
    seed()

    Repo.insert!(%AICall{
      model: "m",
      status: "ok",
      call_type: "jev",
      purpose: "intent",
      latency_ms: 1500,
      cost_micro_usd: 123_456
    })

    {:ok, view, html} = live(conn, ~p"/admin/operate/code-heat")
    refute has_element?(view, "#code-heat-off")
    assert has_element?(view, "#code-heat-sample", "3 modules, 3 functions")
    assert has_element?(view, "#tile-TalesForge-IntentJev[data-hot=true]", "AI")
    assert has_element?(view, "#code-heat-hot", "TalesForge.IntentJev")
    assert has_element?(view, "#ai-jev-intent", "1.5 s")
    refute html =~ "$"
    refute html =~ "0.12"

    view
    |> form("#code-heat-filters", %{
      level: "function",
      metric: "calls",
      module: "approle",
      min: "100000"
    })
    |> render_change()

    assert_patch(view)
    assert has_element?(view, "#tile-TalesForge-AppRole-playtest-1", "1.2M calls")
    refute has_element?(view, "#tile-TalesForge-AppRole-role-1")
    refute has_element?(view, "#tile-TalesForge-IntentJev-read-2")

    {:ok, view, _html} = live(conn, ~p"/admin/operate/code-heat?level=app&metric=avg&min=x")
    assert has_element?(view, "#tile-ex_tales_forge")
  end

  test "format_us/1" do
    assert CodeHeatLive.format_us(12) == "12 µs"
    assert CodeHeatLive.format_us(1.25) == "1.3 µs"
    assert CodeHeatLive.format_us(2500) == "2.5 ms"
    assert CodeHeatLive.format_us(2_500_000) == "2.5 s"
  end
end
