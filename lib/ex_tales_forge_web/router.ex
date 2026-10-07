defmodule TalesForgeWeb.Router do
  @moduledoc """
  Routes: the public play pages, admin login (magic link or GitHub), the protected admin area (with LiveDashboard at /admin/oban and the ExDoc code docs at /admin/code-docs) and, in dev, the Swoosh mailbox.
  """

  use TalesForgeWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TalesForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Public admin auth routes (login / magic link) — no session required.
  pipeline :admin_public do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TalesForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug TalesForgeWeb.Plugs.AdminEmail
  end

  # Protected admin — allowlisted magic-link session only.
  # Player routes never pipe through this; admin data stays isolated.
  pipeline :admin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TalesForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug TalesForgeWeb.Plugs.AdminAuth
  end

  scope "/admin", TalesForgeWeb do
    pipe_through :admin_public

    live_session :admin_login, on_mount: [{TalesForgeWeb.AdminLive.Hooks, :maybe_admin}] do
      live "/login", AdminLive.LoginLive, :index
    end

    post "/login", AdminSessionController, :create
    get "/magic/:token", AdminSessionController, :magic
    get "/auth/github", AdminGithubAuthController, :request
    get "/auth/github/callback", AdminGithubAuthController, :callback
    delete "/logout", AdminSessionController, :delete
  end

  scope "/admin", TalesForgeWeb.AdminLive do
    pipe_through :admin

    live_session :admin, on_mount: [{TalesForgeWeb.AdminLive.Hooks, :require_admin}] do
      live "/", DashboardLive, :index
      live "/sessions", SessionLive.Index, :index
      live "/sessions/:id", SessionLive.Show, :show
      live "/sessions/:id/npcs", NpcLive.Index, :index
      live "/sessions/:id/npcs/:npc_id", NpcLive.Show, :show
      live "/sessions/:id/turns", TurnLive.Index, :index
      live "/playtest", PlaytestLive.Index, :index
      live "/playtest/:id", PlaytestLive.Show, :show
      live "/npc-definitions", NpcDefinitionLive.Index, :index
      live "/npc-definitions/:id", NpcDefinitionLive.Show, :show
      live "/decisions", DecisionLive.Index, :index
      live "/decisions/:slug", DecisionLive.Show, :show
      live "/docs", DocLive.Index, :index
      live "/costs", CostsLive, :index
    end
  end

  scope "/admin" do
    pipe_through :admin

    import Phoenix.LiveDashboard.Router

    live_dashboard "/oban", metrics: TalesForgeWeb.Telemetry
  end

  # ExDoc site built into the release (CodeDocsController). Same :admin
  # pipeline as /admin/costs, so every page and asset needs an admin session.
  scope "/admin", TalesForgeWeb do
    pipe_through :admin

    get "/code-docs/*path", CodeDocsController, :show
  end

  # Machine-to-machine: the peer app's costs page reads this app's aggregated AI
  # spend. Off (404) unless COSTS_PEER_TOKEN is set; see CostsPeerController.
  scope "/internal", TalesForgeWeb do
    pipe_through :api

    get "/costs", CostsPeerController, :show
  end

  scope "/", TalesForgeWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/play/:id", PlayLive, :show
  end

  # Swoosh mailbox preview in development (LiveDashboard lives at /admin/oban)
  if Application.compile_env(:ex_tales_forge, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
