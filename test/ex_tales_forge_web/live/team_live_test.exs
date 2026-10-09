defmodule TalesForgeWeb.TeamLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  doctest TalesForgeWeb.TeamArt

  alias TalesForge.TeamPage
  alias TalesForgeWeb.TeamLive

  # The file the page is built from, read independently of TalesForge.TeamPage.
  @data "priv/team/data.json" |> File.read!() |> Jason.decode!()

  defp render_with(data),
    do: rendered_to_string(TeamLive.render(%{d: data, sections: [], flash: %{}}))

  describe "sign-in" do
    test "signed out, /team redirects to the login page" do
      assert redirected_to(get(build_conn(), ~p"/team")) == "/admin/login"
      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), ~p"/team")
    end

    test "a GitHub user outside the team is refused" do
      conn = log_in_non_member(build_conn())
      assert redirected_to(get(conn, ~p"/team")) == "/admin/login"
    end

    test "a team member sees the page, linked from the admin nav", %{conn: conn} do
      conn = log_in_admin(conn)
      {:ok, view, html} = live(conn, ~p"/team")
      assert html =~ "How Tales Forge gets built"
      assert has_element?(view, "#team-nav a[href='#playtests']", "Playtests")

      {:ok, admin, _html} = live(conn, ~p"/admin")
      assert has_element?(admin, ~s(#admin-nav a[href="/team"]), "Founders' page")
    end
  end

  describe "numbers come from data.json" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the page shows the values in the file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      assert has_element?(view, "#stat-prs-merged", TeamPage.number(@data["pace"]["prs_merged"]))
      assert has_element?(view, "#stat-decisions", TeamPage.number(@data["decisions"]["total"]))
      assert has_element?(view, "#stat-tests", TeamPage.number(@data["pace"]["tests"]["total"]))

      assert has_element?(
               view,
               "#pace-commits",
               TeamPage.number(@data["pace"]["commits_main_ex_tales_forge"])
             )

      assert has_element?(
               view,
               "#hosting",
               TeamPage.usd(@data["infrastructure"]["hosting_total_usd_per_month"])
             )

      assert has_element?(view, "#shadow-latency", TeamPage.ms(@data["intent_shadow"]["p50_ms"]))

      assert has_element?(
               view,
               "#intent-compare",
               TeamPage.usd(@data["intent_compare"]["cost_usd"])
             )

      assert has_element?(
               view,
               "#ai-spend",
               TeamPage.usd(@data["ai_spend"]["documented_total_usd"])
             )

      assert has_element?(
               view,
               "#team-footer",
               "Numbers as of #{TeamPage.date_label(@data["_about"]["as_of"])}"
             )

      for step <- @data["change_flow"]["steps"] do
        assert has_element?(view, "#flow-step-#{step["id"]}", step["label"])
      end

      for persona <- @data["personas"]["items"] do
        assert has_element?(view, "#persona-#{persona["id"]}", persona["character"])
      end

      for run <- @data["gentry_findings"]["hostile_play_results"]["runs"],
          attack <- run["attacks"] do
        assert has_element?(view, "#hostile-#{run["id"]}", attack)
      end
    end

    test "a changed number in the data changes the page (nothing is hard-coded)" do
      data =
        @data
        |> put_in(["pace", "prs_merged"], 12_345)
        |> put_in(["decisions", "total"], 678)
        |> put_in(["infrastructure", "apps", Access.at(0), "release"], "v999")

      html = render_with(data)
      assert html =~ "12,345"
      assert html =~ "678"
      assert html =~ "release v999"
    end

    test "the approval holder comes from the data" do
      data =
        put_in(@data, ["team", "members", Access.at(0), "approval_key", "holder_today"], "Ada")

      html = render_with(data)
      assert html =~ "Right now Ada holds the approval key"
      assert html =~ "Today: Ada · Soon: any founder."
    end
  end

  describe "'not measured yet'" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the empty values in data.json (full batch, holdout) say so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")
      assert @data["playtest_series"]["full_batch"]["weighted"]["paul"] == nil
      assert has_element?(view, "#full-batch", "Paul: not measured yet")
      assert has_element?(view, "#full-batch", "Cost: not measured yet")
      assert @data["intent_eval_set"]["holdout_results"] == nil
      assert has_element?(view, "#eval-holdout", "not measured yet")
    end

    test "missing and null numbers render the text, never a zero" do
      data =
        @data
        |> put_in(["pace", "prs_merged"], nil)
        |> update_in(["decisions"], &Map.delete(&1, "total"))
        |> put_in(["intent_shadow", "p50_ms"], nil)

      html = render_with(data)
      doc = LazyHTML.from_document(html)

      for id <- ~w(stat-prs-merged stat-decisions shadow-latency pace-decisions) do
        text = doc |> LazyHTML.query("##{id}") |> LazyHTML.text()
        assert text =~ "not measured yet", "##{id}: #{text}"
        refute text =~ ~r/\b0\b/, "##{id} shows a zero: #{text}"
      end
    end

    test "an empty data file still renders, every number unmeasured" do
      html = render_with(%{})
      assert html =~ "How Tales Forge gets built"
      assert html =~ "not measured yet"

      assert html =~
               "Hostile-play results (injections, fake GM notes, false claims) will appear here"
    end
  end

  describe "motion" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the page renders the static diagram; motion is decided client-side", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      assert has_element?(view, ~s(#team-page[phx-hook="TeamPage"][data-motion="auto"]))
      assert has_element?(view, ~s(#team-flow[phx-hook="TeamFlow"][data-flow="static"]))
      # Every step is rendered lit (no idle state) until the hook plays it.
      refute has_element?(view, "#team-flow [data-state]")
      assert has_element?(view, "#team-flow [data-flow-replay]")
      assert has_element?(view, "#team-flow [data-flow-token]")
    end

    test "prefers-reduced-motion switches every animation off" do
      css = File.read!("assets/css/app.css")

      [_, block] =
        String.split(css, "@media (prefers-reduced-motion: reduce) {\n  .team-page *", parts: 2)

      assert block =~ "animation: none !important"
      assert block =~ "transition: none !important"
      assert block =~ ".team-flow-token, .team-replay { display: none !important; }"

      # Animations only apply under data-motion="full", which the hook sets only
      # when reduced motion is off.
      rules = ~r/^[^\n{]*\{[^}]*animation: team-[^}]*\}/m |> Regex.scan(css) |> List.flatten()
      # The seal stamp and the two growing bars (the hero's candle flicker went
      # with the SVG hero).
      assert length(rules) >= 3

      for rule <- rules, do: assert(rule =~ ~s([data-motion="full"]), rule)

      js = File.read!("assets/js/team_hooks.js")
      assert js =~ ~s{matchMedia("(prefers-reduced-motion: reduce)")}
      assert js =~ ~s{this.el.dataset.motion = reduce ? "reduce" : "full"}
    end
  end

  describe "illustrations" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the hero is the painted round table: WebP and JPEG, sized, loaded first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      assert has_element?(
               view,
               ~s(#hero picture source[type="image/webp"][srcset*="/images/team/hero-1280.webp 1280w"])
             )

      assert has_element?(
               view,
               ~s(#hero-art[src="/images/team/hero-960.jpg"][width="1280"][height="720"][loading="eager"][fetchpriority="high"])
             )

      assert has_element?(view, ~s(#hero-art[alt*="round tavern table"]))
      refute has_element?(view, "#hero svg.team-hero-art")
    end

    test "the bots' cards show their portraits, lazily; the founders keep their avatar",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      for bot <- ~w(case bobby gentry) do
        assert has_element?(
                 view,
                 ~s(#member-#{bot} img#portrait-#{bot}[loading="lazy"][width="960"][height="720"][srcset*="#{bot}-320.jpg 320w"])
               )

        assert has_element?(
                 view,
                 ~s(#member-#{bot} source[type="image/webp"][srcset*="#{bot}-960.webp 960w"])
               )

        refute has_element?(view, "#member-#{bot} svg.team-avatar")
      end

      assert has_element?(view, ~s(#portrait-gentry[alt*="owl"]))
      refute has_element?(view, "#member-founders img")
      assert has_element?(view, "#member-founders svg.team-avatar")
    end

    test "the founder's OK steps of the flow stamp the painted seal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      seal =
        ~s([data-approval="true"] img.team-seal[src="/images/team/founders-seal-192.jpg"][srcset*="founders-seal-96.jpg 96w"])

      assert has_element?(view, ~s(#flow-step-ok_merge#{seal}[loading="lazy"][width="192"]))
      assert has_element?(view, "#flow-step-ok_prod#{seal}")
      refute has_element?(view, "#team-flow [data-approval] svg.team-seal")
    end

    test "every file in a srcset is committed, in both formats" do
      html = render_with(TalesForge.TeamPage.data())
      files = ~r{/images/team/[a-z-]+-\d+\.(?:webp|jpg)} |> Regex.scan(html) |> List.flatten()

      for name <- TalesForgeWeb.TeamArt.pictures(),
          do: assert(Enum.any?(files, &String.contains?(&1, "/#{name}-")), name)

      for file <- Enum.uniq(files) do
        assert File.exists?(Path.join("priv/static", file)), file
      end

      for file <- Path.wildcard("priv/static/images/team/*.jpg") do
        assert File.exists?(String.replace_suffix(file, ".jpg", ".webp")), file
      end
    end
  end

  test "no secret values on the page", %{conn: conn} do
    {:ok, _view, html} = live(log_in_admin(conn), ~p"/team")
    refute html =~ ~r/xai-[A-Za-z0-9]{10,}|ghp_|API_KEY=/
  end
end
