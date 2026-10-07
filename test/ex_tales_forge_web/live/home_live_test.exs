defmodule TalesForgeWeb.HomeLiveTest do
  use TalesForgeWeb.ConnCase

  test "GET / renders the home live view for a team member", %{conn: conn} do
    conn = conn |> log_in_admin() |> get(~p"/")
    assert html_response(conn, 200) =~ "Your adventures await"
  end
end
