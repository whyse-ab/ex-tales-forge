defmodule TalesForgeWeb.AdminLive.HooksTest do
  # Mutates the endpoint's static manifest config, so not async.
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @endpoint_table TalesForgeWeb.Endpoint

  # The router's live_sessions already run AdminLive.Hooks; a module-level
  # on_mount on top made it run twice and crash with "existing hook
  # :reload_on_stale_assets already attached" once static assets changed.
  test "admin LiveViews don't also declare the admin hooks themselves" do
    for view <- [
          TalesForgeWeb.AdminLive.LoginLive,
          TalesForgeWeb.AdminLive.DecisionLive.Index,
          TalesForgeWeb.AdminLive.DecisionLive.Show,
          TalesForgeWeb.AdminLive.DocLive.Index
        ] do
      hooks = view.__live__().lifecycle.mount

      refute Enum.any?(hooks, &match?({TalesForgeWeb.AdminLive.Hooks, _}, &1.id)),
             "#{inspect(view)} declares on_mount AdminLive.Hooks; the router's live_session already does"
    end
  end

  describe "with stale static assets" do
    setup %{conn: conn} do
      previous = :ets.lookup(@endpoint_table, :cache_static_manifest_latest)

      :ets.insert(
        @endpoint_table,
        {:cache_static_manifest_latest, %{"assets/css/app.css" => "assets/css/app-new.css"}}
      )

      on_exit(fn ->
        case previous do
          [entry] -> :ets.insert(@endpoint_table, entry)
          [] -> :ets.delete(@endpoint_table, :cache_static_manifest_latest)
        end
      end)

      conn = put_connect_params(conn, %{"_track_static" => ["/assets/css/app-old.css"]})
      {:ok, conn: conn}
    end

    test "an admin page reloads instead of crashing", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(log_in_admin(conn), ~p"/admin/docs")
      assert to =~ "/admin/docs"
    end

    test "the login page reloads instead of crashing", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/login")
      assert to =~ "/admin/login"
    end
  end
end
