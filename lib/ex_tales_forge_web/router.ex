defmodule TalesForgeWeb.Router do
  @moduledoc """
  Routes. Everything requires a signed-in member of the ADMIN_GITHUB_TEAM GitHub
  team (`TalesForge.AdminAuth`): the play pages (home, the character creation
  screen at /new/:adventure, a game), the founders' page at /team and its full
  presentation at /team/presentation, the admin area (with LiveDashboard at
  /admin/oban and the ExDoc code docs at /admin/code-docs) and anything added
  later under the `:browser` pipeline. Any team member gets the admin pages;
  there is no separate admin login.

  The only public routes are the login page, the GitHub OAuth request/callback,
  logout, the Fly health check (`/health`) and the token-guarded machine-to-machine
  `/internal/costs`, `/internal/version` and the bots' `/internal/board/*`. Static assets are served by the endpoint before the router.
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

  # LiveDashboard: keep the query on the bare URL, add the admin breadcrumbs.
  pipeline :telemetry do
    plug TalesForgeWeb.Plugs.TelemetryChrome
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

    # The founders' page: a light landing page (TeamLive) and the full
    # presentation (TeamPresentationLive), same team sign-in. Production only
    # (TalesForge.AppRole area :board): their own live_session, so reaching
    # them is a full page load through HomeApp, which sends playtest there.
    live_session :team, on_mount: [{Hooks, :require_team_member}] do
      live "/team", TeamLive, :index
      live "/team/presentation", TeamPresentationLive, :index
    end
  end

  # The admin area, grouped by purpose (decision 2026-10-10; the nav and the
  # home's cards come from TalesForgeWeb.AdminSections): Founders, Play and
  # test, Operate, Develop, Docs and a collapsed Archive.
  scope "/admin", TalesForgeWeb.AdminLive do
    pipe_through :browser

    live_session :admin, on_mount: [{Hooks, :require_team_member}] do
      live "/", DashboardLive, :index
      # Play and test
      live "/play/sessions", SessionLive.Index, :index
      live "/play/sessions/:id", SessionLive.Show, :show
      live "/play/sessions/:id/npcs", NpcLive.Index, :index
      live "/play/sessions/:id/npcs/:npc_id", NpcLive.Show, :show
      live "/play/sessions/:id/turns", TurnLive.Index, :index
      # Operate
      live "/operate/costs", CostsLive, :index
      # Archive
      live "/archive/npc-definitions", NpcDefinitionLive.Index, :index
      live "/archive/npc-definitions/:id", NpcDefinitionLive.Show, :show
    end

    # Pages that live on one app only (TalesForge.AppRole): playtest runs on
    # playtest; surveys, decisions and docs on production. Their own live_sessions, so navigating to
    # them is a full page load through the :browser pipeline, where HomeApp
    # sends them to the other app when they don't live here.
    live_session :admin_playtest, on_mount: [{Hooks, :require_team_member}] do
      live "/play/runs", PlaytestLive.Index, :index
      live "/play/runs/:id", PlaytestLive.Show, :show
    end

    # Founders' decisions and the docs: production only (area :collab).
    live_session :admin_collab, on_mount: [{Hooks, :require_team_member}] do
      live "/founders/decisions", DecisionLive.Index, :index
      live "/founders/decisions/:slug", DecisionLive.Show, :show
      live "/docs", DocLive.Index, :index
      live "/docs/*path", DocLive.Index, :show
    end

    live_session :admin_surveys, on_mount: [{Hooks, :require_team_member}] do
      live "/founders/survey", SurveyLive.Show, :current
      live "/founders/surveys", SurveyLive.Index, :index
      live "/founders/surveys/:id", SurveyLive.Show, :show
      live "/founders/surveys/:id/results", SurveyLive.Results, :index
    end
  end

  scope "/admin" do
    pipe_through [:browser, :telemetry]

    import Phoenix.LiveDashboard.Router

    # Operate: telemetry (LiveDashboard: metrics, processes, Oban, Ecto).
    live_dashboard "/operate/telemetry",
      metrics: TalesForgeWeb.Telemetry,
      home_app: {"Tales Forge", :ex_tales_forge},
      # The way back is the breadcrumb bar (TalesForgeWeb.Plugs.TelemetryChrome).
      # A dashboard menu entry can only link to a dashboard page, so it can't
      # point at /admin#section-operate itself.
      on_mount: [TalesForgeWeb.LiveAuth]
  end

  # The old admin URLs (before the 2026-10-10 regrouping) and everything below
  # them redirect to where the page lives now (TalesForge.AdminPaths), query
  # kept. Behind the sign-in like every admin page; on the wrong app, HomeApp
  # sends the old path across first.
  scope "/admin", TalesForgeWeb do
    pipe_through :browser

    # The section roots (/admin/play, ...) have no page of their own: they
    # open that section on the admin home.
    for {segment, _anchor} <- TalesForge.AdminPaths.section_roots() do
      get "/#{segment}", AdminRedirectController, :section
    end

    for old <- TalesForge.AdminPaths.old_segments() do
      get "/#{old}", AdminRedirectController, :show
      get "/#{old}/*rest", AdminRedirectController, :show
    end
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
    get "/founders/surveys/:id/results.csv", SurveyExportController, :csv
    get "/founders/surveys/:id/results.md", SurveyExportController, :markdown
  end

  # Machine-to-machine: production's costs page reads playtest's aggregated
  # playtest-run AI spend. Answers on the playtest app only, and only while
  # COSTS_PEER_TOKEN is set (404 otherwise); needs it as a bearer token (401);
  # see CostsPeerController. /internal/version (both apps, same token) gives the
  # running commit to the other app's live PR feed on /team; see
  # VersionPeerController. /internal/online (playtest only, same token) gives
  # production's /team the founders online on playtest; see OnlinePeerController.
  # None of them calls an LLM.
  scope "/internal", TalesForgeWeb do
    pipe_through :api

    get "/costs", CostsPeerController, :show
    get "/version", VersionPeerController, :show
    get "/online", OnlinePeerController, :show
  end

  # The founders' idea board's bot API (Case, Bobby and Gentry; production only).
  # Each bot has its own bearer token (BOARD_BOT_TOKEN_<BOT>); see
  # BoardApiController. Off (404) until the board module is deployed.
  scope "/internal/board", TalesForgeWeb do
    pipe_through :api

    get "/ideas", BoardApiController, :index
    get "/ideas/:id", BoardApiController, :show
    post "/ideas/:id/refinement", BoardApiController, :refine
    post "/ideas/:id/move", BoardApiController, :move
    post "/ideas/:id/links", BoardApiController, :link
    post "/ideas/:id/comments", BoardApiController, :comment
    post "/prs", BoardApiController, :pr
  end

  # Swoosh mailbox preview in development (LiveDashboard lives at /admin/operate/telemetry)
  if Application.compile_env(:ex_tales_forge, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
