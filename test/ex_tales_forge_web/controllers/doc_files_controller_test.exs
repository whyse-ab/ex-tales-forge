defmodule TalesForgeWeb.DocFilesControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :tales_forge_docs_path)
      System.delete_env("GITHUB_DOCS_TOKEN")
    end)
  end

  describe "from a local checkout (TALES_FORGE_DOCS_PATH)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "docs_files_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "docs/images"))
      File.write!(Path.join(dir, "docs/images/score.png"), @png)
      File.write!(Path.join(dir, "docs/fly-secrets.md"), "# secrets")
      File.write!(Path.join(dir, "README.png"), @png)
      Application.put_env(:ex_tales_forge, :tales_forge_docs_path, dir)
      on_exit(fn -> File.rm_rf!(dir) end)
    end

    test "serves an image under docs/ to a team member", %{conn: conn} do
      conn = conn |> log_in_admin() |> get("/admin/docs-files/docs/images/score.png")

      assert response(conn, 200) == @png
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
    end

    test "only images, only under docs/, never outside the checkout", %{conn: conn} do
      for path <- [
            "/admin/docs-files/docs/fly-secrets.md",
            "/admin/docs-files/README.png",
            "/admin/docs-files/docs/../README.png",
            "/admin/docs-files/docs/images/missing.png"
          ] do
        assert conn |> recycle() |> log_in_admin() |> get(path) |> response(404)
      end
    end

    test "needs a signed-in team member", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/docs-files/docs/images/score.png")) =~ "/admin/login"
    end
  end

  describe "from GitHub (GITHUB_DOCS_TOKEN)" do
    test "fetches the raw file from the private repo", %{conn: conn} do
      System.put_env("GITHUB_DOCS_TOKEN", "test-token")

      Req.Test.stub(TalesForge.Collab.Files, fn conn ->
        assert conn.request_path ==
                 "/repos/whyse-ab/tales-forge-docs/contents/docs/images/score.png"

        assert Plug.Conn.get_req_header(conn, "accept") == ["application/vnd.github.raw"]
        Plug.Conn.send_resp(conn, 200, @png)
      end)

      conn = conn |> log_in_admin() |> get("/admin/docs-files/docs/images/score.png")
      assert response(conn, 200) == @png
    end

    test "a GitHub error is a 404", %{conn: conn} do
      System.put_env("GITHUB_DOCS_TOKEN", "test-token")
      Req.Test.stub(TalesForge.Collab.Files, &Plug.Conn.send_resp(&1, 404, "{}"))

      assert conn |> log_in_admin() |> get("/admin/docs-files/docs/images/x.png") |> response(404)
    end

    test "no source configured is a 404", %{conn: conn} do
      System.delete_env("GITHUB_DOCS_TOKEN")
      assert conn |> log_in_admin() |> get("/admin/docs-files/docs/images/x.png") |> response(404)
    end
  end
end
