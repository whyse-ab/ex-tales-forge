defmodule TalesForgeWeb.CodeDocsControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    dir = Path.join(System.tmp_dir!(), "code_docs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "dist"))
    File.write!(Path.join(dir, "index.html"), "<html><body>Tales Forge docs</body></html>")
    File.write!(Path.join(dir, "dist/app.js"), "console.log('docs')")
    File.write!(Path.join(dir, "dist/app.css"), "body{}")
    File.write!(Path.join(Path.dirname(dir), "code_docs_secret.txt"), "outside")

    Application.put_env(:ex_tales_forge, :code_docs_dir, dir)

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :code_docs_dir)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  describe "admin" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "gets the index page", %{conn: conn} do
      conn = get(conn, "/admin/code-docs/")
      assert html_response(conn, 200) =~ "Tales Forge docs"
      assert get_resp_header(conn, "cache-control") == ["private, max-age=300"]
    end

    test "gets assets with their content type", %{conn: conn} do
      js = get(conn, "/admin/code-docs/dist/app.js")
      assert response(js, 200) == "console.log('docs')"
      assert [type] = get_resp_header(js, "content-type")
      assert type =~ "javascript"

      css = get(conn, "/admin/code-docs/dist/app.css")
      assert response(css, 200) == "body{}"
      assert get_resp_header(css, "content-type") == ["text/css"]
    end

    # ConnTest skips CSRF protection by default, which hid a 403 on every
    # docs .js file in the browser. Turn it back on as a real request has it.
    test "JS assets pass the CSRF cross-origin JS check", %{conn: conn} do
      js =
        conn
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> get("/admin/code-docs/dist/app.js")

      assert response(js, 200) == "console.log('docs')"
    end

    test "no trailing slash redirects so relative links resolve", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/code-docs")) == "/admin/code-docs/"
    end

    test "missing files and paths outside the folder are 404", %{conn: conn} do
      assert response(get(conn, "/admin/code-docs/nope.html"), 404)
      assert response(get(conn, "/admin/code-docs/../code_docs_secret.txt"), 404)
      assert response(get(conn, "/admin/code-docs/%2E%2E/code_docs_secret.txt"), 404)
      assert response(get(conn, "/admin/code-docs/dist/..%2F..%2Fcode_docs_secret.txt"), 404)
    end

    test "docs not built: 404 with the build command", %{conn: conn, dir: dir} do
      File.rm_rf!(dir)
      assert response(get(conn, "/admin/code-docs/"), 404) =~ "mix docs -f html -o priv/code_docs"
    end

    test "linked from the admin nav as a full page load", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/costs")
      link = element(view, ~s(#admin-nav a[href="/admin/code-docs/"]), "Code docs")
      assert render(link) =~ ~s(href="/admin/code-docs/")
      refute render(link) =~ "data-phx-link"
    end
  end

  test "anonymous and non-team users are redirected to login, pages and assets" do
    for conn <- [build_conn(), log_in_non_member(build_conn())],
        path <- [
          "/admin/code-docs",
          "/admin/code-docs/",
          "/admin/code-docs/index.html",
          "/admin/code-docs/dist/app.js"
        ] do
      assert redirected_to(get(conn, path)) =~ "/admin/login"
    end
  end

  test "not served by the public static path" do
    assert response(get(build_conn(), "/code-docs/index.html"), 404)
    refute "code_docs" in TalesForgeWeb.static_paths()
  end
end
