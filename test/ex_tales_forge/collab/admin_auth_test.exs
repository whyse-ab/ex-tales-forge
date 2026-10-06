defmodule TalesForge.AdminAuthTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  test "expired and no-longer-allowlisted tokens are rejected and consumed" do
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    future = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)

    {:ok, expired} =
      %MagicToken{}
      |> MagicToken.changeset(%{email: "founder@example.com", token: "expired", expires_at: past})
      |> Repo.insert()

    {:ok, stranger} =
      %MagicToken{}
      |> MagicToken.changeset(%{
        email: "stranger@example.com",
        token: "stranger",
        expires_at: future
      })
      |> Repo.insert()

    assert {:error, :expired} = AdminAuth.verify_token(expired.token)
    assert {:error, :not_allowlisted} = AdminAuth.verify_token(stranger.token)
    assert Repo.all(MagicToken) == []
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

  # test.exs doesn't enable :dev_routes, so this is the prod behaviour.
  test "login page and flash don't point at /dev/mailbox without dev routes" do
    refute get(build_conn(), ~p"/admin/login") |> html_response(200) =~ "/dev/mailbox"

    conn = post(build_conn(), ~p"/admin/login", %{"email" => "founder@example.com"})
    assert redirected_to(conn) == "/admin/login"
    flash = Phoenix.Flash.get(conn.assigns.flash, :info)
    assert flash == "If that email is allowlisted, a login link is on its way."
  end

  test "magic-link login sets a 30-day session cookie (not secure outside prod)" do
    :ok = AdminAuth.request_magic_link("founder@example.com")
    [token] = Repo.all(MagicToken)

    conn = get(build_conn(), ~p"/admin/magic/#{token.token}")
    assert redirected_to(conn) == "/admin"

    cookie = conn.resp_cookies["_ex_tales_forge_key"]
    assert cookie.max_age == 2_592_000
    refute cookie[:secure]

    header = conn |> get_resp_header("set-cookie") |> Enum.find(&(&1 =~ "_ex_tales_forge_key="))
    assert header =~ "max-age=2592000"
    refute header =~ ~r/;\s*secure/i
  end

  test "removing an email from the allowlist revokes an existing session" do
    :ok = AdminAuth.request_magic_link("founder@example.com")
    [token] = Repo.all(MagicToken)
    conn = get(build_conn(), ~p"/admin/magic/#{token.token}")

    # Same browser (cookie) on a later request is still signed in...
    assert conn |> recycle() |> get(~p"/admin") |> html_response(200) =~ "Dashboard"

    original = Application.get_env(:ex_tales_forge, :admin_emails)
    on_exit(fn -> Application.put_env(:ex_tales_forge, :admin_emails, original) end)
    Application.put_env(:ex_tales_forge, :admin_emails, ["other@example.com"])

    # ...until the email leaves the allowlist: plug and LiveView mount both refuse.
    assert conn |> recycle() |> get(~p"/admin") |> redirected_to() == "/admin/login"

    assert {:error, {:redirect, %{to: "/admin/login"}}} =
             live(recycle(conn), ~p"/admin")
  end
end
