defmodule TalesForgeWeb.TeamLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  doctest TalesForgeWeb.TeamArt
  doctest TalesForgeWeb.TeamCallTypes

  alias TalesForge.TeamPage
  alias TalesForgeWeb.TeamCallTypes
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

  describe "the call-type rule: one turn, three call types" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    defp walkthrough_detail(data, lane) do
      data["call_types"]["walkthrough"]["steps"]
      |> Enum.find(&(&1["lane"] == lane))
      |> Map.fetch!("detail")
    end

    test "rule 3 links to the walkthrough, which sits under it in 'How we work'", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")
      anchor = TeamCallTypes.anchor()

      assert has_element?(
               view,
               ~s(#rule-call-types a[href="##{anchor}"]),
               "one turn, three call types"
             )

      assert has_element?(
               view,
               "#how ##{anchor} h3",
               "The call-type rule: one turn, three call types"
             )

      assert has_element?(view, "##{anchor}", "This one rule shapes the whole game engine")
    end

    test "the rule in one breath: three pills in the call-type colours, with the why", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/team")

      for kind <- ~w(elixir jev llm) do
        css_var = @data["call_types"]["colours"][kind]["css_var"]

        assert has_element?(
                 view,
                 ~s|#pill-#{kind}.team-kind-#{kind}[style="--team-kind: var(#{css_var})"]|
               )
      end

      assert has_element?(view, "#pill-elixir", "Elixir function.")
      assert has_element?(view, "#pill-elixir", "a test can prove it")
      assert has_element?(view, "#pill-jev", "Jev call (TypeSafe).")
      assert has_element?(view, "#pill-jev", "about 0.25 s a read")

      assert has_element?(
               view,
               "#pill-jev",
               "median #{TeamPage.ms(@data["intent_shadow"]["p50_ms"])} in the shadow test"
             )

      assert has_element?(
               view,
               "#pill-jev",
               "for about #{TeamPage.usd(@data["intent_shadow"]["cost_per_turn_usd"])} a turn"
             )

      assert has_element?(view, "#pill-llm", "LLM call (the GM on Grok).")
      assert has_element?(view, "#pill-llm", "so we never ask it for data")

      assert has_element?(
               view,
               "#calltype-smell",
               "The LLM tells the story; it doesn't keep the books."
             )
    end

    test "one turn, start to finish, from the walkthrough data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")
      jev = walkthrough_detail(@data, "jev")
      elixir = walkthrough_detail(@data, "elixir")

      assert has_element?(
               view,
               "#calltype-player",
               @data["call_types"]["walkthrough"]["player_text"]
             )

      assert has_element?(
               view,
               "#calltype-turn",
               "The private room is listed at 3 silver a night"
             )

      for field <- ~w(action target skill safety) do
        assert has_element?(view, "#turn-jev-intent", jev[field])
      end

      assert has_element?(view, "#turn-jev-intent", "this turn (nothing deferred)")
      assert has_element?(view, "#turn-jev-intent", "benign")
      assert has_element?(view, "#turn-jev-intent", "(no trick, no injection)")

      assert has_element?(
               view,
               "#turn-jev-intent",
               "0.92, so act on it without asking the player to clarify"
             )

      assert has_element?(view, "#turn-roll", "1d20, roll-under")

      assert has_element?(
               view,
               "#turn-roll",
               "The character's persuasion is #{elixir["skill_level"]}"
             )

      assert has_element?(view, "#turn-roll", "Charisma bonus (CHA 14 gives +2)")
      assert has_element?(view, "#turn-roll", "so the target is #{elixir["target"]}")
      assert has_element?(view, "#turn-roll", "The die shows #{elixir["die"]}: success")
      assert has_element?(view, "#turn-elixir", "a success earns nothing to learn from")
      assert has_element?(view, "#turn-elixir", "it sinks in when you sleep")

      assert has_element?(
               view,
               "#turn-llm",
               "persuasion, success, Brenna, room listed at 3 silver"
             )

      assert has_element?(view, "#turn-prose", "She slides a heavy iron key across the oak.")
      assert has_element?(view, "#turn-llm", "Sample prose, written to show the style")
      assert has_element?(view, "#calltype-honesty", "How true is this today?")
      assert has_element?(view, "#calltype-honesty", "there is no haggling-discount rule yet")

      assert has_element?(
               view,
               "#calltype-honesty",
               "live on both playtest and production, switched on 9 Oct 2026 after the shadow test"
             )
    end

    test "examples per type and the closing line", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      for module <-
            ~w(Game.Mechanics Game.Progression World.Prices Game.PremiseCheck Game.WorldClock Game.Gestures) do
        assert has_element?(view, "#examples-elixir code", module)
      end

      for module <- ~w(Game.JevIntent Game.NpcReactions Playtest.JevScorer) do
        assert has_element?(view, "#examples-jev code", module)
      end

      assert has_element?(view, "#examples-jev", "decided, not built yet")
      assert has_element?(view, "#examples-llm", "GM narration:")
      assert has_element?(view, "#examples-llm", "NPC dialogue:")

      assert has_element?(
               view,
               "#calltype-closing",
               "Elixir keeps the rules, Jev understands the players, and the GM tells the story."
             )
    end

    test "one turn, three lanes: Jev on top, then Elixir, then the GM, in the page's colours",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")
      elixir = walkthrough_detail(@data, "elixir")

      assert has_element?(view, ~s(#team-lanes[phx-hook="TeamLanes"][data-lanes="static"]))
      assert has_element?(view, "#team-lanes [data-lanes-replay].team-replay")

      for svg <- ~w(team-lanes-wide team-lanes-tall) do
        lanes =
          view
          |> render()
          |> LazyHTML.from_document()
          |> LazyHTML.query("##{svg} [data-lane]")
          |> Enum.map(&(&1 |> LazyHTML.attribute("data-lane") |> hd()))

        assert lanes == TeamCallTypes.lanes(), svg

        for lane <- lanes do
          css_var = @data["call_types"]["colours"][lane]["css_var"]

          assert has_element?(
                   view,
                   ~s|##{svg} [data-lane="#{lane}"].team-kind-#{lane}[style="--team-kind: var(#{css_var})"]|
                 )
        end

        for step <- @data["call_types"]["walkthrough"]["steps"],
            do: assert(has_element?(view, "##{svg} [data-lane='#{step["lane"]}']", step["label"]))

        # Five numbered steps, each with a text label, so colour is never the only cue.
        for n <- 1..5,
            do: assert(has_element?(view, "##{svg} [data-at='#{n}'] .tl-badge", "#{n}"))

        assert has_element?(view, "##{svg}", "speak · Brenna")
        assert has_element?(view, "##{svg}", "~0.25 s")
        assert has_element?(view, "##{svg} .tl-die", "#{elixir["die"]}")
        assert has_element?(view, "##{svg}", "target #{elixir["target"]}")
        assert has_element?(view, "##{svg} .tl-stamp", "✓ success")
        assert has_element?(view, "##{svg}", "nothing to learn from a success")
        assert has_element?(view, "##{svg}", "room: 3 silver (price list)")
        assert has_element?(view, "##{svg} .tl-smell-group", "LLM → data?")
        assert has_element?(view, "##{svg} .tl-smell-group", "That's a smell.")
        assert has_element?(view, "##{svg} .tl-cross")
        assert has_element?(view, "##{svg} [data-at='5']", "player")
      end

      # Wide lanes from 1024 px, stacked lanes below (no sideways scroll on phones).
      assert has_element?(view, "#team-lanes-wide.hidden.w-full.lg\\:block")
      assert has_element?(view, "#team-lanes-tall.w-full.lg\\:hidden")
      assert has_element?(view, "#team-lanes figcaption.sr-only", "One turn in five steps.")
    end

    test "a changed walkthrough changes the page (nothing is hard-coded)" do
      data =
        @data
        |> put_in(["intent_shadow", "p50_ms"], 410)
        |> put_in(["call_types", "walkthrough", "player_text"], "I offer Brenna two copper.")
        |> update_in(["call_types", "walkthrough", "steps"], fn steps ->
          Enum.map(steps, fn
            %{"lane" => "elixir"} = step ->
              step
              |> put_in(["detail", "die"], 13)
              |> put_in(["detail", "target"], 11)
              |> put_in(["detail", "room_price"], "5 silver (price list)")

            %{"lane" => "jev"} = step ->
              put_in(step, ["detail", "confidence"], 0.77)

            step ->
              step
          end)
        end)

      html = render_with(data)
      assert html =~ "I offer Brenna two copper."
      assert html =~ "The die shows <strong>13</strong>"
      assert html =~ "so the target is <strong>11</strong>"
      assert html =~ "listed at 5 silver a night"
      assert html =~ "speak · Brenna · persuasion · now · 0.77 · safe"
      assert html =~ "~0.41 s"
      assert html =~ "about 0.41 s a read"
      assert html =~ "median 410 ms in the shadow test"
    end

    test "null and missing values in the walkthrough read 'not measured yet', never a zero" do
      data =
        @data
        |> put_in(["intent_shadow", "p50_ms"], nil)
        |> put_in(["intent_shadow", "cost_per_turn_usd"], nil)
        |> update_in(["call_types", "walkthrough", "steps"], fn steps ->
          Enum.map(steps, fn
            %{"lane" => "elixir"} = step ->
              step
              |> put_in(["detail", "die"], nil)
              |> update_in(["detail"], &Map.delete(&1, "target"))

            %{"lane" => "jev"} = step ->
              put_in(step, ["detail", "confidence"], nil)

            step ->
              step
          end)
        end)

      doc = data |> render_with() |> LazyHTML.from_document()
      text = &(doc |> LazyHTML.query(&1) |> LazyHTML.text())

      assert text.("#turn-roll") =~ "so the target is not measured yet"
      assert text.("#turn-roll") =~ "The die shows not measured yet"
      assert text.("#turn-jev-intent") =~ ~r/confidence\s+not measured yet/
      assert text.("#pill-jev") =~ "not measured yet a read"
      assert text.("#pill-jev") =~ "for about not measured yet a turn"
      assert text.("#team-lanes-wide") =~ ~r/lands on\s+not measured yet/
      assert text.("#team-lanes-wide") =~ ~r/target\s+not measured yet/
      assert text.("#team-lanes-wide") =~ "persuasion · now · not measured yet · safe"
      refute text.("#team-lanes-wide") =~ ~r/target\s+0\b|lands on\s+0\b/
    end

    test "without any call-type data the walkthrough still renders" do
      html = render_with(%{})
      assert html =~ "The call-type rule: one turn, three call types"
      assert html =~ "One turn, three lanes"
      assert html =~ "I lean on the bar and try to talk Brenna down on the price of the room."
      assert html =~ "The die shows <strong>not measured yet</strong>"
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

    test "the three lanes only move with motion allowed; reduced motion shows the static diagram" do
      css = File.read!("assets/css/app.css")

      # Hiding and moving the lanes' parts happens only while playing, only under
      # data-motion="full".
      lane_rules =
        ~r/^[^\n{]*\.team-lanes[^\n{]*\{[^}]*(?:opacity: 0;|transform: translate|animation: team-)[^}]*\}/m
        |> Regex.scan(css)
        |> List.flatten()

      assert length(lane_rules) >= 8

      for rule <- lane_rules do
        assert rule =~ ~s(.team-page[data-motion="full"] .team-lanes[data-lanes="playing"]), rule
      end

      [_, block] =
        String.split(css, "@media (prefers-reduced-motion: reduce) {\n  .team-page *", parts: 2)

      assert block =~
               ".team-lanes [data-at] { opacity: 1 !important; transform: none !important; }"

      js = File.read!("assets/js/team_hooks.js")
      [_, lanes_js] = String.split(js, "export const TeamLanes = {", parts: 2)
      assert lanes_js =~ "this.mq = reducedMotion()"

      assert lanes_js =~
               "if (this.mq.matches || !(\"IntersectionObserver\" in window)) return this.settle()"

      assert lanes_js =~ ~s{this.el.dataset.lanes = "static"}

      app_js = File.read!("assets/js/app.js")
      assert app_js =~ "TeamLanes"
    end

    test "the lanes' colours follow the theme: CSS variables with a dark variant, no fixed lane colours" do
      css = File.read!("assets/css/app.css")

      for var <- ~w(--team-jev --team-elixir --team-llm) do
        assert css =~ ~r/\.team-page \{[^}]*#{var}: #/
        assert css =~ ~r/:root\[data-theme="dark"\] \.team-page \{[^}]*#{var}: #/
      end

      lanes_css =
        ~r/^\.team-lanes \.tl-[^\n]*$/m |> Regex.scan(css) |> List.flatten() |> Enum.join("\n")

      refute lanes_css =~ ~r/#[0-9a-fA-F]{3,6}\b/, "lane styles use the page's variables only"
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
      assert has_element?(view, ~s(#hero-art[alt*="stylised Nordic adventurers"]))

      for name <- ~w(Fredrik Thobias Håkan Jeanette) do
        assert has_element?(view, ~s(#hero-art[alt*="#{name}"]))
      end

      assert has_element?(view, ~s(#hero-art[alt*="Max the apprentice"]))

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
