defmodule TalesForgeWeb.TelemetryChromeTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  doctest TalesForgeWeb.Plugs.TelemetryChrome

  alias TalesForgeWeb.AdminSections

  test "the bare dashboard URL keeps its query on the way to /home", %{conn: conn} do
    conn = get(log_in_admin(conn), "/admin/operate/telemetry?refresh=5&nav=x")
    assert redirected_to(conn) == "/admin/operate/telemetry/home?refresh=5&nav=x"
  end

  test "without a query it still goes to /home", %{conn: conn} do
    assert redirected_to(get(log_in_admin(conn), "/admin/operate/telemetry")) ==
             "/admin/operate/telemetry/home"
  end

  test "signed out, the dashboard sends you to the admin login first", %{conn: conn} do
    assert redirected_to(get(conn, "/admin/operate/telemetry?refresh=5")) =~ "/admin/login"
  end

  test "every dashboard page has the breadcrumb back to the admin area", %{conn: conn} do
    html = conn |> log_in_admin() |> get("/admin/operate/telemetry/home") |> html_response(200)
    doc = LazyHTML.from_document(html)
    crumbs = LazyHTML.query(doc, "body > nav#telemetry-crumbs")
    assert LazyHTML.text(crumbs) =~ "Admin"
    assert LazyHTML.text(crumbs) =~ "Telemetry"
    assert "/admin" in LazyHTML.attribute(LazyHTML.query(crumbs, "a"), "href")
    assert "/admin#section-operate" in LazyHTML.attribute(LazyHTML.query(crumbs, "a"), "href")
  end

  test "the logs of the other app look like every other cross-app link", %{conn: conn} do
    items = Enum.flat_map(AdminSections.sections(), & &1.items)
    playtest_logs = Enum.find(items, &(&1[:app] == :playtest))
    runs = Enum.find(items, &(&1[:area] == :playtest_runs))

    assert AdminSections.link_label(playtest_logs, :production) == "Logs (playtest) ↗"
    assert AdminSections.cross_app?(playtest_logs, :production)
    assert AdminSections.cross_app?(runs, :production)
    refute AdminSections.cross_app?(playtest_logs, :playtest)

    Application.put_env(:ex_tales_forge, :app_name, "tales-forge")
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :app_name) end)
    {:ok, _view, html} = live(log_in_admin(conn), "/admin")

    # The same look: the other app's logs on the home have the class of the
    # other cross-app links.
    doc0 = LazyHTML.from_document(html)

    class_of = fn t ->
      doc0
      |> LazyHTML.query("main a[data-cross-app]")
      |> Enum.find(&(LazyHTML.text(&1) =~ t))
      |> LazyHTML.attribute("class")
    end

    assert class_of.("Logs (playtest)") == class_of.("Playtest runs (")
    doc = LazyHTML.from_document(html)

    for {selector, text} <- [{"#admin-nav", "Playtest runs ("}, {"main", "Logs (playtest) ↗"}] do
      cross =
        doc
        |> LazyHTML.query("#{selector} a[data-cross-app]")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert Enum.any?(cross, &(&1 =~ text)),
             "#{selector}: no #{text} in #{inspect(cross)}"
    end
  end

  test "the old '← Admin › Operate' menu page goes to the admin home's Operate section", %{
    conn: conn
  } do
    conn = get(log_in_admin(conn), "/admin/operate/telemetry/admin")
    assert redirected_to(conn) == "/admin#section-operate"
  end

  test "the dashboard menu has no entry that points inside the dashboard for the way back", %{
    conn: conn
  } do
    html = conn |> log_in_admin() |> get("/admin/operate/telemetry/home") |> html_response(200)
    refute html =~ "/admin/operate/telemetry/admin"
    assert html =~ ~s(href="/admin#section-operate")
  end
end
