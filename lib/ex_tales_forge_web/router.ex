defmodule TalesForgeWeb.Router do
  @moduledoc """
  Routes. Everything requires a signed-in member of the ADMIN_GITHUB_TEAM GitHub
  team (`TalesForge.AdminAuth`): the play pages (home, the character creation
  screen at /new/:adventure, a game), the admin area (with
  LiveDashboard at /admin/oban and the ExDoc code docs at /admin/code-docs) and
  anything added later under the `:browser` pipeline. Any team member gets the
  admin pages; there is no separate admin login.

  The only public routes are the login page, the GitHub OAuth request/callback,
  logout, the Fly health check (`/health`) and the token-guarded machine-to-machine
  `/internal/costs`. Static assets are served by the endpoint before the router.
  """

  use TalesForgeWeb, :router

  alias TalesForgeWeb.AdminLive.Hooks
  alias TalesForgeWeb.Plugs.HomeApp
  alias TalesForgeWeb.Plugs.RequireTeamMember

  # HTML basics, no sign-in required. Only for the login and OAuth routes below.
  pipeline :public_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TalesForgeWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # The default for every page: pages that live on the other app (surveys on
  # production, playtest runs on playtest; TalesForge.AppRole) redirect there,
  # then a signed-in GitHub team member, otherwise a redirect to /admin/login. LiveViews are also checked on mount (the
  # live_sessions below plus `TalesForgeWeb.LiveAuth` in every `:live_view`), so
  # a websocket connect can't skip this plug.
  pipeline :browser do
    plug :public_browser
    plug HomeApp
    plug RequireTeamMember
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Fly health check (fly.toml / fly.playtest.toml). No session, no pipeline.
  get "/health", TalesForgeWeb.HealthController, :show

  scope "/admin", TalesForgeWeb do
    pipe_through :public_browser

    live_session :login, on_mount: [{Hooks, :maybe_team_member}] do
      live "/login", AdminLive.LoginLive, :index
    end

    get "/auth/github", AdminGithubAuthController, :request
    get "/auth/github/callback", AdminGithubAuthController, :callback
    delete "/logout", AdminSessionController, :delete
  end

  scope "/", TalesForgeWeb do
    pipe_through :browser

    live_session :play, on_mount: [{Hooks, :require_team_member}] do
      live "/", HomeLive, :index
      live "/new/:adventure", CreateCharacterLive, :new
      live "/play/:id", PlayLive, :show
    end
  end

  scope "/admin", TalesForgeWeb.AdminLive do
    pipe_through :browser

    live_session :admin, on_mount: [{Hooks, :require_team_member}] do
      live "/", DashboardLive, :index
      live "/sessions", SessionLive.Index, :index
      live "/sessions/:id", SessionLive.Show, :show
      live "/sessions/:id/npcs", NpcLive.Index, :index
      live "/sessions/:id/npcs/:npc_id", NpcLive.Show, :show
      live "/sessions/:id/turns", TurnLive.Index, :index
      live "/npc-definitions", NpcDefinitionLive.Index, :index
      live "/npc-definitions/:id", NpcDefinitionLive.Show, :show
      live "/decisions", DecisionLive.Index, :index
      live "/decisions/:slug", DecisionLive.Show, :show
      live "/docs", DocLive.Index, :index
      live "/docs/*path", DocLive.Index, :show
      live "/costs", CostsLive, :index
    end

    # Pages that live on one app only (TalesForge.AppRole): playtest runs on
    # playtest, surveys on production. Their own live_sessions, so navigating to
    # them is a full page load through the :browser pipeline, where HomeApp
    # sends them to the other app when they don't live here.
    live_session :admin_playtest, on_mount: [{Hooks, :require_team_member}] do
      live "/playtest", PlaytestLive.Index, :index
      live "/playtest/:id", PlaytestLive.Show, :show
    end

    live_session :admin_surveys, on_mount: [{Hooks, :require_team_member}] do
      live "/survey", SurveyLive.Show, :current
      live "/surveys", SurveyLive.Index, :index
      live "/surveys/:id", SurveyLive.Show, :show
      live "/surveys/:id/results", SurveyLive.Results, :index
    end
  end

  scope "/admin" do
    pipe_through :browser

    import Phoenix.LiveDashboard.Router

    live_dashboard "/oban",
      metrics: TalesForgeWeb.Telemetry,
      on_mount: [TalesForgeWeb.LiveAuth]
  end

  # ExDoc site built into the release (CodeDocsController) and the images of
  # the docs viewer. Every page and asset needs a signed-in team member, like
  # the rest of the app.
  scope "/admin", TalesForgeWeb do
    pipe_through :browser

    get "/code-docs/*path", CodeDocsController, :show

    # Images in tales-forge-docs pages (the repo is private; DocFilesController).
    get "/docs-files/*path", DocFilesController, :show

    # Founder survey result downloads (team members only, like every page).
    get "/surveys/:id/results.csv", SurveyExportController, :csv
    get "/surveys/:id/results.md", SurveyExportController, :markdown
  end

  # Machine-to-machine: the peer app's costs page reads this app's aggregated AI
  # spend. Off (404) unless COSTS_PEER_TOKEN is set, and then needs it as a
  # bearer token; see CostsPeerController. Never calls an LLM.
  scope "/internal", TalesForgeWeb do
    pipe_through :api

    get "/costs", CostsPeerController, :show
  end

  # Swoosh mailbox preview in development (LiveDashboard lives at /admin/oban)
  if Application.compile_env(:ex_tales_forge, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
