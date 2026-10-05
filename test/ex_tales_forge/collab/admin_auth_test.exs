defmodule TalesForge.AdminAuthTest do
  use TalesForgeWeb.ConnCase, async: false

  alias TalesForge.AdminAuth
  alias TalesForge.Collab.Schemas.MagicToken
  alias TalesForge.Repo

  test "allowlist accepts configured emails only" do
    assert AdminAuth.allowlisted?("founder@example.com")
    refute AdminAuth.allowlisted?("stranger@example.com")
  end

  test "non-allowlisted email does not create a token but returns ok" do
    assert :ok = AdminAuth.request_magic_link("stranger@example.com")
    assert Repo.all(MagicToken) == []
  end

  test "allowlisted email creates a verifiable token" do
    assert :ok = AdminAuth.request_magic_link("founder@example.com")
    [token] = Repo.all(MagicToken)
    assert {:ok, "founder@example.com"} = AdminAuth.verify_token(token.token)
    # one-time use
    assert {:error, :invalid} = AdminAuth.verify_token(token.token)
  end

  test "non-allowlisted session cannot reach /admin" do
    conn =
      build_conn()
      |> init_test_session(%{})
      |> put_session(AdminAuth.session_key(), "stranger@example.com")
      |> get(~p"/admin")

    assert redirected_to(conn) == "/admin/login"
  end

  test "allowlisted session can reach /admin" do
    conn = log_in_admin(build_conn()) |> get(~p"/admin")
    assert html_response(conn, 200) =~ "Dashboard"
  end

  test "anonymous cannot reach /admin" do
    conn = get(build_conn(), ~p"/admin")
    assert redirected_to(conn) == "/admin/login"
  end
end
