defmodule TalesForgeWeb.AdminSections do
  @moduledoc """
  The admin area grouped by purpose (decision 2026-10-10): the one list that
  both the admin nav (the `nav` component in `Layouts.admin`) and the admin
  home's cards (`TalesForgeWeb.AdminLive.DashboardLive`) are drawn from.

  - **Founders**: the founders' pages, the founder survey and the decisions.
  - **Play and test**: playtest runs and what they measure (personas, Jev's
    scoring, character changes), and the game sessions.
  - **Operate**: costs and Jev intent latency, telemetry, health, logs.
  - **Develop**: code docs, architecture, the call types.
  - **Docs**: the shared docs (rules, world, design notes).
  - **Archive** (collapsed): old pages that still work but are rarely needed.

  Each item is a page or a place on a page. `nav: true` items are also in the
  nav; the home lists them all. An item with an `area` lives on one app only
  (`TalesForge.AppRole`): on the other app its link goes there (`href/1`) and
  its label names that app. Items under /team, the decisions and the docs get
  their area from their path (`TalesForge.AppRole.area_for_path/1`).
  """

  alias TalesForge.AppRole

  @typedoc "A section's id."
  @type id :: :founders | :play | :operate | :develop | :docs | :archive

  @typedoc """
  One link. `key` is the `active` name a page passes to `Layouts.admin`
  (marks it in the nav); `kind` is `:live` (a LiveView in the `:admin` live
  session, `navigate`), `:page` (a full page load: another live session, a
  controller, `/team`) or `:external` (another site, new tab).
  """
  @type item :: %{
          required(:label) => String.t(),
          required(:path) => String.t(),
          required(:kind) => :live | :page | :external,
          optional(:key) => String.t(),
          optional(:fragment) => String.t(),
          optional(:area) => AppRole.area(),
          optional(:app) => :production | :playtest,
          optional(:nav) => boolean()
        }

  @typedoc "A section: a card on the home, a group in the nav."
  @type section :: %{id: id(), title: String.t(), line: String.t(), items: [item()]}

  @plain_sections [
    %{
      id: :founders,
      title: "Founders",
      line: "Who we are, the founder survey, and what we have decided.",
      items: [
        %{
          label: "Founders' page and PR feed ↗",
          path: "/team",
          kind: :page,
          key: "team",
          nav: true
        },
        %{label: "Presentation ↗", path: "/team/presentation", kind: :page, nav: true},
        %{
          label: "Founder survey",
          path: "/admin/founders/survey",
          kind: :page,
          key: "survey",
          area: :surveys,
          nav: true
        },
        %{
          label: "Decision queue (page)",
          path: "/admin/founders/decisions",
          kind: :live,
          key: "decisions",
          nav: true
        },
        %{label: "Decision log (doc)", path: "/admin/docs/decisions.md", kind: :live},
        %{label: "Roadmap 2027", path: "/admin/docs/roadmap-2027.md", kind: :live}
      ]
    },
    %{
      id: :play,
      title: "Play and test",
      line: "Bot playtests, how they scored, and the games themselves.",
      items: [
        %{
          label: "Playtest runs",
          path: "/admin/play/runs",
          kind: :page,
          key: "playtest",
          area: :playtest_runs,
          nav: true
        },
        %{
          label: "Character changes",
          path: "/admin/play/runs",
          fragment: "batch-character-changes",
          kind: :page,
          area: :playtest_runs
        },
        %{label: "Personas", path: "/admin/docs/personas.md", kind: :live},
        %{label: "Jev scoring", path: "/admin/docs/jev-scoring.md", kind: :live},
        %{
          label: "Game sessions",
          path: "/admin/play/sessions",
          kind: :live,
          key: "sessions",
          nav: true
        }
      ]
    },
    %{
      id: :operate,
      title: "Operate",
      line: "What it costs, how it runs, and what is deployed where.",
      items: [
        %{label: "Costs", path: "/admin/operate/costs", kind: :live, key: "costs", nav: true},
        %{
          label: "Jev intent latency",
          path: "/admin/operate/costs",
          fragment: "costs-intent-latency",
          kind: :live
        },
        %{
          label: "Telemetry and AI calls",
          path: "/admin/operate/telemetry",
          kind: :page,
          key: "oban",
          nav: true
        },
        %{
          label: "Code heat map",
          path: "/admin/operate/code-heat",
          kind: :live,
          key: "code_heat",
          nav: true
        },
        %{label: "Health check", path: "/health", kind: :page},
        %{
          label: "Logs",
          path: "https://fly.io/apps/tales-forge/monitoring",
          kind: :external,
          app: :production
        },
        %{
          label: "Logs",
          path: "https://fly.io/apps/tales-forge-playtest/monitoring",
          kind: :external,
          app: :playtest
        }
      ]
    },
    %{
      id: :develop,
      title: "Develop",
      line: "How the code is built and how each turn's AI calls are split.",
      items: [
        %{
          label: "Code docs",
          path: "/admin/code-docs/",
          kind: :page,
          key: "code_docs",
          nav: true
        },
        %{
          label: "Architecture",
          path: "/admin/docs/architecture-baseline-2026-10-09.md",
          kind: :live
        },
        %{label: "Call types", path: "/admin/docs/call-types.md", kind: :live},
        %{label: "Coding standards", path: "/admin/docs/coding-standards.md", kind: :live},
        %{label: "Environments", path: "/admin/docs/environments.md", kind: :live}
      ]
    },
    %{
      id: :docs,
      title: "Docs",
      line: "The shared docs: rules, the world, and design notes.",
      items: [
        %{label: "All docs", path: "/admin/docs", kind: :live, key: "docs", nav: true},
        %{
          label: "Rules: skills economy",
          path: "/admin/docs/design-skills-economy.md",
          kind: :live
        },
        %{
          label: "World: Tin Valley",
          path: "/admin/docs/design-tin-valley-world.md",
          kind: :live
        },
        %{
          label: "World: stateful world",
          path: "/admin/docs/design-stateful-world.md",
          kind: :live
        },
        %{label: "Examples of play", path: "/admin/docs/examples-of-play.md", kind: :live},
        %{
          label: "Design: playtest loop",
          path: "/admin/docs/design-playtest-loop.md",
          kind: :live
        }
      ]
    },
    %{
      id: :archive,
      title: "Archive",
      line: "Old pages that still work but are rarely needed.",
      items: [
        %{
          label: "NPC definitions (base pack)",
          path: "/admin/archive/npc-definitions",
          kind: :live,
          key: "npc_definitions",
          nav: true
        }
      ]
    }
  ]

  # Every item that lives on one app gets that app's area from its path
  # (TalesForge.AppRole.area_for_path/1, the one map of path to home), so the
  # nav marks it by home and links there from the other app.
  @sections Enum.map(@plain_sections, fn section ->
              items =
                Enum.map(section.items, fn item ->
                  case {item, AppRole.area_for_path(item.path)} do
                    {%{area: _}, _area} -> item
                    {_item, nil} -> item
                    {_item, area} -> Map.put(item, :area, area)
                  end
                end)

              %{section | items: items}
            end)

  @doc """
  Every section, in order (Archive last).

      iex> TalesForgeWeb.AdminSections.sections() |> Enum.map(& &1.title)
      ["Founders", "Play and test", "Operate", "Develop", "Docs", "Archive"]
  """
  @spec sections() :: [section()]
  def sections, do: @sections

  @doc """
  The section a page belongs to, from the `active` name it passes to
  `Layouts.admin`, or nil (the home).

      iex> TalesForgeWeb.AdminSections.section_of("costs").title
      "Operate"
      iex> TalesForgeWeb.AdminSections.section_of("dashboard")
      nil
  """
  @spec section_of(String.t() | nil) :: section() | nil
  def section_of(key) do
    Enum.find(@sections, fn section -> Enum.any?(section.items, &(&1[:key] == key)) end)
  end

  @typedoc "One breadcrumb: its label and link (nil for the page being shown)."
  @type crumb :: {String.t(), String.t() | nil}

  @doc """
  The breadcrumbs of an admin page, Admin > Section > Page, from the `active`
  name it passes to `Layouts.admin` and, optionally, the name of the page
  itself (`page`, e.g. one decision's title). The last crumb has no link.
  Pages without a section (the home) get just "Admin". `Layouts.admin` draws
  them on every admin page.

      iex> TalesForgeWeb.AdminSections.breadcrumbs("dashboard")
      [{"Admin", nil}]
      iex> TalesForgeWeb.AdminSections.breadcrumbs("costs")
      [{"Admin", "/admin"}, {"Operate", "/admin#section-operate"}, {"Costs", nil}]
      iex> TalesForgeWeb.AdminSections.breadcrumbs("decisions", "Confirm the rewrite")
      [{"Admin", "/admin"}, {"Founders", "/admin#section-founders"}, {"Decision queue", "/admin/founders/decisions"}, {"Confirm the rewrite", nil}]
      iex> TalesForgeWeb.AdminSections.breadcrumbs("unknown", "Some page")
      [{"Admin", "/admin"}, {"Some page", nil}]
  """
  @spec breadcrumbs(String.t() | nil, String.t() | nil, AppRole.role()) :: [crumb()]
  def breadcrumbs(active, page \\ nil, role \\ AppRole.role()) do
    case {section_of(active), page} do
      {nil, nil} ->
        [{"Admin", nil}]

      {nil, page} ->
        [{"Admin", "/admin"}, {page, nil}]

      {section, page} ->
        item = Enum.find(section.items, &(&1[:key] == active))
        item = %{item | label: crumb_label(item.label)}
        head = [{"Admin", "/admin"}, {section.title, "/admin#section-#{section.id}"}]

        if page in [nil, item.label],
          do: head ++ [{item.label, nil}],
          else: head ++ [{item.label, href(item, role)}, {page, nil}]
    end
  end

  # A nav label without its "(page)" / "↗" markers, for the breadcrumbs.
  defp crumb_label(label),
    do: label |> String.replace(~r/\s*\([^)]*\)|\s*↗/u, "") |> String.trim()

  @doc """
  The URL of `item` on this app: its path (and `#fragment`), or for a page
  that lives on the other app the full URL there (`TalesForge.AppRole.link/3`).
  """
  @spec href(item(), AppRole.role()) :: String.t()
  def href(item, role \\ AppRole.role()) do
    base =
      case item do
        %{area: area} -> AppRole.link(area, item.path, role)
        _ -> item.path
      end

    case item do
      %{fragment: fragment} -> base <> "#" <> fragment
      _ -> base
    end
  end

  @doc """
  True when `item` is a page on the other app (its label then says which).

      iex> item = %{label: "Founder survey", path: "/admin/founders/survey", kind: :page, area: :surveys}
      iex> TalesForgeWeb.AdminSections.elsewhere?(item, :playtest)
      true
      iex> TalesForgeWeb.AdminSections.elsewhere?(item, :production)
      false
  """
  @spec elsewhere?(item(), AppRole.role()) :: boolean()
  def elsewhere?(item, role \\ AppRole.role())
  def elsewhere?(%{area: area}, role), do: not AppRole.here?(area, role)
  def elsewhere?(_item, _role), do: false

  @doc """
  True when `item` belongs to the other app: a page that lives there
  (`elsewhere?/2`), or an outside link about the other app (`:app`, for
  example the playtest logs on production). These links get the cross-app
  look in the nav and on the admin home.

      iex> logs = %{label: "Logs", path: "https://fly.io/apps/tales-forge-playtest/monitoring", kind: :external, app: :playtest}
      iex> TalesForgeWeb.AdminSections.cross_app?(logs, :production)
      true
      iex> TalesForgeWeb.AdminSections.cross_app?(logs, :playtest)
      false
  """
  @spec cross_app?(item(), AppRole.role()) :: boolean()
  def cross_app?(item, role \\ AppRole.role())
  def cross_app?(%{app: app}, role), do: role != :local and app != role
  def cross_app?(item, role), do: elsewhere?(item, role)

  @doc """
  The link text of `item`: its label, then the app in brackets for a page on
  the other app or a link about one app, then "↗" for a link that leaves the
  page's app or the site.

      iex> logs = %{label: "Logs", path: "https://fly.io/apps/tales-forge-playtest/monitoring", kind: :external, app: :playtest}
      iex> TalesForgeWeb.AdminSections.link_label(logs, :production)
      "Logs (playtest) ↗"
      iex> runs = %{label: "Playtest runs", path: "/admin/play/runs", kind: :live, area: :playtest_runs}
      iex> TalesForgeWeb.AdminSections.link_label(runs, :production)
      "Playtest runs (playtest) ↗"
      iex> TalesForgeWeb.AdminSections.link_label(runs, :playtest)
      "Playtest runs"
  """
  @spec link_label(item(), AppRole.role()) :: String.t()
  def link_label(item, role \\ AppRole.role()) do
    cond do
      Map.has_key?(item, :app) ->
        "#{item.label} (#{item.app}) ↗"

      elsewhere?(item, role) ->
        "#{String.trim_trailing(item.label, " ↗")} (#{AppRole.home_label(item.area)}) ↗"

      item.kind == :external ->
        item.label <> " ↗"

      true ->
        item.label
    end
  end
end
