defmodule TalesForgeWeb.TeamPresentationLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  doctest TalesForgeWeb.TeamArt
  doctest TalesForgeWeb.TeamCallTypes
  doctest TalesForgeWeb.TeamPresentationLive
  doctest TalesForgeWeb.TeamBoard
  doctest TalesForgeWeb.TeamPeek

  alias TalesForge.PrFeed
  alias TalesForge.TeamPage
  alias TalesForgeWeb.TeamBoard
  alias TalesForgeWeb.TeamCallTypes
  alias TalesForgeWeb.TeamPresentationLive

  # The file the page is built from, read independently of TalesForge.TeamPage.
  @data "priv/team/data.json" |> File.read!() |> Jason.decode!()

  defp render_with(data),
    do: rendered_to_string(TeamPresentationLive.render(%{d: data, sections: [], flash: %{}}))

  describe "sign-in" do
    test "signed out, /team/presentation redirects to the login page" do
      assert redirected_to(get(build_conn(), ~p"/team/presentation")) == "/admin/login"

      assert {:error, {:redirect, %{to: "/admin/login"}}} =
               live(build_conn(), ~p"/team/presentation")
    end

    test "a GitHub user outside the team is refused" do
      conn = log_in_non_member(build_conn())
      assert redirected_to(get(conn, ~p"/team/presentation")) == "/admin/login"
    end

    test "a team member sees the whole presentation, with a way back to /team", %{conn: conn} do
      conn = log_in_admin(conn)
      {:ok, view, html} = live(conn, ~p"/team/presentation")
      assert html =~ "How Tales Forge gets built"
      assert page_title(view) =~ "presentation"

      for {id, label} <- TeamPresentationLive.sections() do
        assert has_element?(view, "#team-nav a[href='##{id}']", label)
        assert has_element?(view, "section##{id}")
      end

      assert has_element?(view, ~s(#team-nav a#team-nav-overview[href="/team"]), "Overview")

      assert {:ok, _landing, landing_html} =
               view |> element("#team-nav-overview") |> render_click() |> follow_redirect(conn)

      assert landing_html =~ "The full presentation"
    end
  end

  describe "peeks: hover cards on the call-type pills" do
    setup %{conn: conn} do
      {:ok, view, html} = live(log_in_admin(conn), ~p"/team/presentation")
      {:ok, view: view, doc: LazyHTML.from_document(html)}
    end

    test "each pill has an accessible button and a closed card", %{view: view, doc: doc} do
      for kind <- ~w(elixir jev llm) do
        assert has_element?(view, "#pill-#{kind} #peek-#{kind}[data-peek]")

        button = LazyHTML.query(doc, "#peek-#{kind}-button")
        assert LazyHTML.attribute(button, "type") == ["button"]
        assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
        assert LazyHTML.attribute(button, "aria-controls") == ["peek-#{kind}-card"]
        assert LazyHTML.attribute(button, "aria-describedby") == ["peek-#{kind}-gist"]
        assert has_element?(view, "#peek-#{kind}-card #peek-#{kind}-gist")
        assert has_element?(view, "#peek-#{kind}-card[aria-labelledby='peek-#{kind}-title']")

        # Closed until the hook opens it; the fade only with motion allowed.
        [class] = doc |> LazyHTML.query("#peek-#{kind}-card") |> LazyHTML.attribute("class")
        assert class =~ "invisible"
        assert class =~ "group-data-[open]/peek:visible"
        assert class =~ "max-w-[calc(100vw-2rem)]"
        refute class =~ ~r/(^|\s)transition/
        assert class =~ "motion-safe:transition"
      end
    end

    test "Elixir: a short, highlighted roll-under check", %{view: view, doc: doc} do
      code = doc |> LazyHTML.query("#peek-elixir-code") |> LazyHTML.text()
      lines = String.split(code, "\n", trim: true)
      assert length(lines) in 8..12
      assert Enum.all?(lines, &(String.length(&1) <= 40)), "fits a 390 px phone"

      for part <- ["@spec roll", "effective_level(char, skill)", ":rand.uniform(20)"] do
        assert code =~ part
      end

      for outcome <- ~w(:success :partial_success :failure), do: assert(code =~ outcome)
      assert has_element?(view, "#peek-elixir-code span", "@spec")
      assert has_element?(view, "#peek-elixir-code span", ":partial_success")
      assert has_element?(view, "#peek-elixir-card", "Game.Mechanics")
    end

    test "Jev: the player's words and context in, the typed intent out", %{view: view, doc: doc} do
      assert has_element?(
               view,
               "#peek-jev-words",
               @data["call_types"]["walkthrough"]["player_text"]
             )

      assert has_element?(view, "#peek-jev-card", "valley_inn")
      assert has_element?(view, "#peek-jev-card", "Brenna")

      json = doc |> LazyHTML.query("#peek-jev-output") |> LazyHTML.text() |> Jason.decode!()

      assert json == %{
               "action" => "speak",
               "target" => "brenna",
               "skill" => "persuasion",
               "timing" => "now",
               "confidence" => 0.92,
               "safety" => "benign"
             }
    end

    test "GM: the typed result in, prose out", %{view: view, doc: doc} do
      json = doc |> LazyHTML.query("#peek-llm-input") |> LazyHTML.text() |> Jason.decode!()
      elixir = Enum.find(@data["call_types"]["walkthrough"]["steps"], &(&1["lane"] == "elixir"))
      assert json["outcome"] == elixir["detail"]["outcome"]
      assert json["roll"] == elixir["detail"]["die"]
      assert {json["skill"], json["target"]} == {"persuasion", "brenna"}
      assert has_element?(view, "#peek-llm-prose", "Brenna laughs")
    end

    test "every replay button is always shown, labelled and reachable by keyboard", %{doc: doc} do
      buttons =
        LazyHTML.query(doc, "[data-flow-replay], [data-lanes-replay], [data-board-replay]")

      assert Enum.count(buttons) == 3

      for button <- buttons do
        [label] = LazyHTML.attribute(button, "aria-label")
        assert label =~ ~r/^Replay the animation of /
        assert LazyHTML.attribute(button, "type") == ["button"]
        [class] = LazyHTML.attribute(button, "class")
        # app.css hides `.team-replay` until motion is on (and with reduced
        # motion); these buttons don't carry it, so they always show.
        refute class =~ ~r/(^|\s)team-replay(\s|$)/
        refute class =~ ~r/(^|\s)(hidden|invisible|sr-only|opacity-0)(\s|$)/
        assert LazyHTML.attribute(button, "tabindex") in [[], ["0"]]
      end
    end

    test "the hook handles hover, focus, tap and Esc" do
      js = File.read!("assets/js/team_hooks.js")

      for part <-
            ~w(setupPeeks pointerover focusin focusout Escape aria-expanded data-peek-trigger) do
        assert js =~ part
      end
    end

    test "without call-type data the cards still render, nothing crashes" do
      html = render_with(Map.delete(@data, "call_types"))
      assert html =~ ~s(id="peek-jev-output")
      assert html =~ "not measured yet"
    end
  end

  describe "one source for the pace numbers (TalesForge.TeamPace)" do
    import TalesForge.PrFeedFixtures

    setup %{conn: conn} do
      on_exit(fn -> :ets.delete(PrFeed.Poller, :snapshot) end)
      {:ok, conn: log_in_admin(conn)}
    end

    # The pace numbers as rendered in the headline stats and in section 5.
    defp pace_numbers(html) do
      doc = LazyHTML.from_document(html)
      text = &(doc |> LazyHTML.query(&1) |> LazyHTML.text() |> String.trim())

      %{
        headline: %{
          merged: text.("#stat-prs-merged > span:first-child"),
          source: text.("#stat-source")
        },
        section: %{merged: text.("#pace-prs-merged"), source: text.("#pace-source")},
        total: text.("#pace-prs > span:first-child"),
        open: text.("#pace-prs-open"),
        commits: text.("#pace-commits > span:first-child")
      }
    end

    test "live: the headline and section 5 show the same live numbers, and follow the feed",
         %{conn: conn} do
      PrFeed.publish(snapshot([], pace: pace()))
      {:ok, view, html} = live(conn, ~p"/team/presentation")

      n = pace_numbers(html)
      assert n.headline == n.section
      assert n.headline.merged == "1,111"
      assert n.headline.source == "Pull request and commit numbers: live from GitHub."
      assert {n.total, n.open, n.commits} == {"1,234", "77", "4,321"}
      assert has_element?(view, "#stat-source[data-source=live]")
      assert has_element?(view, "#pace-source[data-source=live]")
      # PRs per day come from the same live count: the earlier month is one chip.
      assert has_element?(view, "#prs-earlier-chip", "+5 PRs in September")

      # A new feed broadcast updates both places at once.
      send(view.pid, {:pr_feed, snapshot([], pace: pace(%{prs_merged: 1200, commits: 4400}))})
      n = view |> render() |> pace_numbers()
      assert n.headline == n.section
      assert {n.headline.merged, n.commits} == {"1,200", "4,400"}
    end

    test "fallback: no live count, both show data.json, labelled 'as of <date>'", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/team/presentation")

      as_of =
        "Pull request and commit numbers: as of #{TeamPage.date_label(@data["pace"]["as_of"])}."

      n = pace_numbers(html)
      assert n.headline == n.section
      assert n.headline.merged == TeamPage.number(@data["pace"]["prs_merged"])
      assert n.headline.source == as_of
      assert n.total == TeamPage.number(@data["pace"]["prs_total"])
      assert n.commits == TeamPage.number(@data["pace"]["commits_main_ex_tales_forge"])
      assert has_element?(view, "#stat-source[data-source=fallback]")
      assert has_element?(view, "#pace-source[data-source=fallback]")

      # The feed going down after a live count drops both back together.
      send(view.pid, {:pr_feed, snapshot([], pace: pace())})
      assert view |> render() |> pace_numbers() |> get_in([:section, :merged]) == "1,111"
      send(view.pid, {:pr_feed, PrFeed.empty(:unavailable, DateTime.utc_now())})
      n = view |> render() |> pace_numbers()
      assert n.headline == n.section
      assert n.headline.source == as_of
    end

    test "rendered without a mount, the numbers fall back to the data it is given" do
      data = put_in(@data, ["pace", "prs_merged"], 4242)
      n = data |> render_with() |> pace_numbers()
      assert n.headline == n.section
      assert n.headline.merged == "4,242"
    end
  end

  describe "numbers come from data.json" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the page shows the values in the file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")
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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")
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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")
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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")
      elixir = walkthrough_detail(@data, "elixir")

      assert has_element?(view, ~s(#team-lanes[phx-hook="TeamLanes"][data-lanes="static"]))
      assert has_element?(view, "#team-lanes [data-lanes-replay].team-replay-btn")

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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

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

      for name <- ~w(Fredrik Thobias Håkan Jeanette Max) do
        assert has_element?(view, ~s(#hero-art[alt*="#{name}"]))
      end

      assert has_element?(view, ~s(#hero-art[alt*="The five founders"]))
      assert has_element?(view, ~s(#hero-art[alt*="our vibe-coding founder and RPG apprentice"]))
      refute has_element?(view, ~s(#hero-art[alt*="Max the apprentice"]))

      refute has_element?(view, "#hero svg.team-hero-art")
    end

    test "the bots' cards show their portraits, lazily; the founders keep their avatar",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

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
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

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

  describe "6. one shared board (coming soon)" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "sits between pace and together, badged as not built, with the brief's copy", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, ~p"/team/presentation")
      anchor = TeamBoard.anchor()

      ids =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("main > section")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert ids == ["hero" | Enum.map(TeamPresentationLive.sections(), &elem(&1, 0))]
      assert Enum.drop(ids, 5) == ["pace", anchor, "together"]

      assert has_element?(view, "##{anchor} h2", "6. How we'll work together: one shared board")
      assert has_element?(view, "#together h2", "7. Where we go from here, together")
      assert has_element?(view, "#board-badge", "Coming soon. Not built yet.")
      assert has_element?(view, "##{anchor}", "one shared board where every feature lives")

      assert has_element?(
               view,
               "#board-caption",
               "Coming soon: one board, the whole crew, from idea to done."
             )

      assert has_element?(view, "#board-why", "Moving a card pings the right bot.")
      assert has_element?(view, "#board-why", "One place for each thing.")
      assert has_element?(view, "#board-why", "not just Fredrik as today")
      assert has_element?(view, ~s(#board-small-print a[href="/admin/decisions"]))
      assert has_element?(view, "#board-small-print", "Founder kanban on /team")
      assert has_element?(view, "#board-step-founder_check", "That drag is the founder's OK.")

      assert has_element?(
               view,
               ~s(#involve-board a[href="##{anchor}"]),
               "The shared board"
             )

      assert has_element?(view, "#involve-board", "Soon: put your ideas on the board.")
    end

    test "the columns, owners and pings come from shared_board in data.json", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team/presentation")
      board = @data["shared_board"]

      for col <- board["columns"] do
        assert has_element?(view, "#board-col-#{col["id"]}", col["label"])
        assert has_element?(view, "#board-step-#{col["id"]}", col["label"])

        if col["on_enter"],
          do:
            assert(
              has_element?(view, "#board-col-#{col["id"]} .team-board-enter", col["on_enter"])
            ),
          else: refute(has_element?(view, "#board-col-#{col["id"]} .team-board-enter"))
      end

      assert has_element?(view, "#board-travel", "Five columns")
      assert has_element?(view, ~s(#board-col-refining svg.team-avatar[aria-label="Case"]))
      assert has_element?(view, ~s(#board-col-building svg.team-avatar[aria-label="Bobby"]))

      assert has_element?(
               view,
               ~s(#board-col-founder_check svg.team-avatar[aria-label="The founders"])
             )

      assert has_element?(view, "#board-as-of", "Board plan as of 9 Oct 2026")

      # The static board: the sample card once in every column, labelled.
      for col <- board["columns"] do
        assert has_element?(
                 view,
                 "#board-col-#{col["id"]} .team-board-card",
                 board["sample_card"]["title"]
               )
      end

      assert has_element?(view, "#board-col-refining", "rough cost: small")
      assert has_element?(view, "#board-col-founder_check", "Only after the second visit?")
      assert has_element?(view, "#board-col-building", "Founder OK")
      assert has_element?(view, "#board-col-building", "decision logged")
      assert has_element?(view, "#board-col-building [data-at='5']", "playtest")
      assert has_element?(view, "#board-col-done", "Shipped")
    end

    test "a mock, not a board: static until the hook plays it, and nothing to drag", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team/presentation")

      assert has_element?(view, ~s(#team-board[phx-hook="TeamBoard"][data-board="static"]))
      assert has_element?(view, "#team-board [data-board-replay].team-replay-btn")
      refute has_element?(view, "#team-board [data-shown]")
      refute has_element?(view, "#team-board [data-gone]")
      refute has_element?(view, "#team-board [draggable]")
      refute has_element?(view, "#team-board [phx-click]")
      refute has_element?(view, "#team-board form")

      steps =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#team-board .team-board-card")
        |> Enum.map(&(&1 |> LazyHTML.attribute("data-at") |> hd()))

      assert steps == ~w(1 2 3 4 6)

      # Stacked on a phone, five across from 1024 px: no sideways scroll.
      assert has_element?(view, "#team-board-columns.grid.sm\\:grid-cols-2.lg\\:grid-cols-5")
    end

    test "null and missing board values read 'not measured yet', never a zero" do
      data =
        @data
        |> put_in(["shared_board", "as_of"], nil)
        |> put_in(["shared_board", "sample_card", "title"], nil)
        |> update_in(["shared_board", "columns"], fn cols ->
          Enum.map(cols, fn
            %{"id" => "refining"} = col -> Map.merge(col, %{"label" => nil, "on_enter" => nil})
            %{"id" => "done"} = col -> Map.delete(col, "label")
            col -> col
          end)
        end)

      doc = data |> render_with() |> LazyHTML.from_document()
      text = &(doc |> LazyHTML.query(&1) |> LazyHTML.text())

      assert text.("#board-as-of") =~ "Board plan as of not measured yet"
      refute text.("#board-as-of") =~ ~r/\b0\b/

      for col <- ~w(ideas refining founder_check building done) do
        assert text.("#board-col-#{col} .team-board-card") =~ "not measured yet"
      end

      # A missing label falls back to the brief's name for the column.
      assert text.("#board-col-refining header") =~ "Refining (Case)"
      assert text.("#board-col-done header") =~ "Done"
      refute doc |> LazyHTML.query("#board-col-refining .team-board-enter") |> Enum.any?()
    end

    test "without any board data the section still renders the brief's five columns" do
      html = render_with(%{})
      doc = LazyHTML.from_document(html)

      assert html =~ "6. How we&#39;ll work together: one shared board"
      assert doc |> LazyHTML.query("#team-board .team-board-col") |> Enum.count() == 5
      assert doc |> LazyHTML.query("#board-as-of") |> LazyHTML.text() =~ "not measured yet"

      assert doc |> LazyHTML.query("#board-why") |> LazyHTML.text() =~
               "not just one founder as today"
    end

    test "the board's motion is client-side, off with reduced motion" do
      css = File.read!("assets/css/app.css")

      [motion_css, block] =
        String.split(css, "@media (prefers-reduced-motion: reduce) {\n  .team-page *", parts: 2)

      board_rules =
        ~r/^[^\n{]*\.team-board[^\n{]*\{[^}]*(?:opacity: 0;|transform: |animation: team-)[^}]*\}/m
        |> Regex.scan(motion_css)
        |> List.flatten()
        # Static layout, not motion: the "pinged" tag is centred under its
        # avatar, and the d20 confetti only ever shows while playing.
        |> Enum.reject(&String.starts_with?(&1, [".team-board-ping {", ".team-board-d20 {"]))

      assert length(board_rules) >= 8

      for rule <- board_rules,
          do: assert(rule =~ ~s(.team-page[data-motion="full"] .team-board[data-board=), rule)

      assert block =~
               ".team-board [data-at], .team-board [data-gone] { opacity: 1 !important; transform: none !important; }"

      js = File.read!("assets/js/team_hooks.js")
      [_, board_js] = String.split(js, "export const TeamBoard = {", parts: 2)
      assert board_js =~ "this.mq = reducedMotion()"

      assert board_js =~
               "if (this.mq.matches || !(\"IntersectionObserver\" in window)) return this.settle()"

      assert board_js =~ ~s{this.el.dataset.board = "static"}
      assert File.read!("assets/js/app.js") =~ "TeamBoard"
    end
  end

  describe "the sub-nav on a phone" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "wraps instead of running off the side (Gentry: ~568 px on a 390 px phone)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/team/presentation")
      doc = view |> render() |> LazyHTML.from_document()

      classes =
        &(doc |> LazyHTML.query(&1) |> LazyHTML.attribute("class") |> hd() |> String.split())

      assert "flex-wrap" in classes.("#team-nav-list")

      for selector <- ["#team-header", "#team-nav", "#team-nav-list"],
          class <- classes.(selector) do
        refute class =~
                 ~r/^(?:overflow-x-(?:auto|scroll)|whitespace-nowrap|flex-nowrap|w-max|min-w-max)$/,
               "#{selector} has #{class}"
      end

      # No sideways scroll anywhere on the page.
      refute render(view) =~ ~r/class="[^"]*\boverflow-x-(?:auto|scroll)\b/
    end
  end

  describe "the founders: five, Max among them" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the founders' card names all five and has a warm word for Max", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team/presentation")
      people = hd(@data["team"]["members"])["people"]

      assert people["count"] == 5
      assert length(people["names"]) == 5

      assert has_element?(
               view,
               "#member-founders #founders-people",
               "We're five: Fredrik, Thobias, Håkan, Jeanette and Max."
             )

      assert has_element?(
               view,
               "#member-founders #founders-people",
               "Max, our vibe-coding founder and RPG apprentice, has never played a tabletop RPG."
             )

      refute render(view) =~ ~r/four founders|Max the apprentice/
    end

    test "a missing count reads 'not measured yet'; no names, no line" do
      no_count =
        update_in(@data, ["team", "members", Access.at(0), "people"], &Map.delete(&1, "count"))

      assert render_with(no_count) =~ ~r"We(&#39;|')re not measured yet: Fredrik"

      no_people =
        update_in(@data, ["team", "members", Access.at(0)], &Map.delete(&1, "people"))

      html = render_with(no_people)
      refute html =~ "founders-people"
      refute html =~ "Welcome to the table, Max!"
    end
  end

  describe "copy from the latest brief" do
    test "the future-ideas list has all three ideas, in a proper list" do
      html = render_with(@data)
      assert @data["decisions"]["future_ideas"]["count"] == 3

      assert html =~
               "3 ideas so far: <em>speculative intent while typing, memory consolidation and attitude drift and a founder kanban on /team</em>"
    end

    test "the shadow test is told in the past tense" do
      html = render_with(@data)
      assert html =~ "We replaced a keyword guesser with Jev"
      refute html =~ "We&#39;re replacing"
    end

    test "every anchor an old /team# link may use is on this page" do
      ids =
        @data
        |> render_with()
        |> LazyHTML.from_document()
        |> LazyHTML.query("[id]")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      for anchor <- TeamPresentationLive.anchors(), do: assert(anchor in ids, anchor)
      assert TeamPresentationLive.anchors() == Enum.uniq(TeamPresentationLive.anchors())
    end
  end

  test "no secret values on the page", %{conn: conn} do
    {:ok, _view, html} = live(log_in_admin(conn), ~p"/team/presentation")
    refute html =~ ~r/xai-[A-Za-z0-9]{10,}|ghp_|API_KEY=/
  end
end
