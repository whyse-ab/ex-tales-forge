defmodule TalesForgeWeb.PlayLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, Turn}

  setup %{conn: conn} do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  test "play surface hides skill, roll, outcome, and LP", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Living Tin Valley", adventure_id: "tin_valley"})

    {:ok, _view, html} = live(conn, ~p"/play/#{session.id}")

    assert html =~ "Time"
    assert html =~ "Location"
    assert html =~ "wounds"
    assert html =~ "Coins"
    assert html =~ "Inventory"
    assert html =~ "Brenna"
    refute html =~ "fee_copper"

    refute_sheet(html)

    assert {:ok, %{status: :processing}} =
             GameSessions.submit_message(session.id, "search the inn")

    turn =
      Turn
      |> Repo.all()
      |> Enum.find(&(&1.game_session_id == session.id))

    assert is_integer(turn.mechanical_resolution["roll"])
    assert turn.mechanical_resolution["outcome"] in ["success", "partial_success", "failure"]

    {:ok, _view, html} = live(conn, ~p"/play/#{session.id}")
    refute_sheet(html)
  end

  test "dead session disables play input", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Dead Elara", adventure_id: "tin_valley"})

    world = put_in(session.world_state, ["character", "vitality"], "dead")

    session
    |> GameSession.changeset(%{status: "dead", world_state: world})
    |> Repo.update!()

    {:ok, view, html} = live(conn, ~p"/play/#{session.id}")

    assert html =~ "You are dead."
    assert html =~ "dead"
    assert has_element?(view, "input[name=message][disabled]")
    assert has_element?(view, "button[type=submit][disabled]")
  end

  test "re-rendering mid-turn keeps the GM placeholder out of the stream", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Thinking Tin Valley", adventure_id: "tin_valley"})

    {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")

    send(view.pid, {:turn_processing, %{}})
    assert render(view) =~ "The GM is thinking…"

    # A stream insert while the placeholder is showing used to raise
    # "setting phx-update to \"stream\" requires setting an ID on each child".
    send(
      view.pid,
      {:npc_initiative,
       %{npc_id: "brenna", npc_name: "Brenna", world_tick: 1, text: "Brenna waves."}}
    )

    html = render(view)
    assert html =~ "Brenna waves."
    assert html =~ "The GM is thinking…"
    refute has_element?(view, "#narrative-log > p")

    send(view.pid, {:turn_failed, "boom"})
    refute render(view) =~ "The GM is thinking…"
  end

  test "a spend cap shows a calm message, not a failure", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Capped Tin Valley", adventure_id: "tin_valley"})

    {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")

    send(view.pid, {:turn_processing, %{}})
    send(view.pid, {:turn_failed, {:spend_cap, :day}})

    html = render(view)
    assert html =~ "resting until tomorrow"
    refute html =~ "Turn failed"
    refute html =~ "The GM is thinking…"
  end

  describe "clarification questions" do
    import TalesForge.PlaytestHelpers

    setup do
      on_exit(fn ->
        System.put_env("LLM_PROVIDER", "mock")
        System.delete_env("XAI_API_KEY")
        System.delete_env("TIER1_HEURISTIC_THRESHOLD")
      end)

      {:ok, session} =
        GameSessions.create_session(%{name: "Which way", adventure_id: "tin_valley"})

      # The intent LLM asks back on every action; the player's words are kept
      # with the pending question on the session.
      System.put_env("TIER1_HEURISTIC_THRESHOLD", "1.0")
      stub_llm(fn kind, _user -> if kind == :intent, do: clarifying_intent(), else: :default end)

      assert {:ok, %{status: :clarification}} =
               GameSessions.submit_message(session.id, "I go over there.")

      # The GM turn after the pick runs on the offline mock.
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")

      {:ok, session: session}
    end

    test "the question survives a reload, and an option plays the words it asked about",
         %{conn: conn, session: session} do
      # A fresh mount is a reload: the question comes back from the session.
      {:ok, view, html} = live(conn, ~p"/play/#{session.id}")
      assert html =~ "Which way?"
      assert has_element?(view, ~s(button[phx-value-option_id="inn"]), "Ask the innkeeper")

      view |> element(~s(button[phx-value-option_id="inn"])) |> render_click()

      html = render(view)
      refute html =~ "Say something first."
      refute html =~ "Which way?"

      assert [%Turn{player_action: "I go over there."}] =
               Turn |> Repo.all() |> Enum.filter(&(&1.game_session_id == session.id))

      refute Map.has_key?(Repo.get!(GameSession, session.id).world_state, "pending_clarification")
    end

    test "the question also appears live, without a reload", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")

      question =
        GameSessions.pending_clarification(Repo.get!(GameSession, session.id).world_state)

      send(view.pid, {:clarification_needed, Map.put(question, "question", "Left or right?")})
      assert render(view) =~ "Left or right?"
    end

    test "an option of a question that has passed asks for a new action",
         %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")

      session = Repo.get!(GameSession, session.id)
      world = Map.delete(session.world_state, "pending_clarification")
      session |> GameSession.changeset(%{world_state: world}) |> Repo.update!()

      view |> element(~s(button[phx-value-option_id="inn"])) |> render_click()

      html = render(view)
      assert html =~ "That question has passed."
      refute html =~ "Which way?"
      refute html =~ "Say something first."
    end
  end

  test "Act reads Thinking… and is disabled while a turn is in flight", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Busy Tin Valley", adventure_id: "tin_valley"})

    {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")
    assert has_element?(view, "#act-button:not([disabled])", "Act")

    send(view.pid, {:turn_processing, %{}})
    assert has_element?(view, ~s(#act-button[disabled][aria-busy="true"]), "Thinking…")
    assert has_element?(view, "input[name=message][disabled]")

    send(view.pid, {:turn_failed, "boom"})
    assert has_element?(view, "#act-button:not([disabled])", "Act")
  end

  test "the story fills the phone screen and has a New text below button", %{conn: conn} do
    {:ok, session} =
      GameSessions.create_session(%{name: "Scroll Tin Valley", adventure_id: "tin_valley"})

    {:ok, view, _html} = live(conn, ~p"/play/#{session.id}")

    assert has_element?(view, "#story-column[class*='100dvh']")
    assert has_element?(view, "#story-scroll[phx-hook=StoryScroll]")

    assert has_element?(
             view,
             ~s(#story-new-text-region[phx-update="ignore"][aria-live="polite"] #story-new-text[hidden][aria-controls="story-scroll"]),
             "New text below"
           )
  end

  defp clarifying_intent do
    %{
      "overall_intent" => "go somewhere",
      "actions" => [
        %{"action_type" => "speak", "target" => "innkeep", "parameters" => %{}},
        %{"action_type" => "move", "target" => "market_square", "parameters" => %{}}
      ],
      "primary_index" => 0,
      "confidence" => 0.4,
      "needs_clarification" => true,
      "clarification_question" => "Which way?",
      "clarification_options" => [
        %{"id" => "inn", "label" => "Ask the innkeeper", "action_index" => 0},
        %{"id" => "square", "label" => "Walk to the square", "action_index" => 1}
      ]
    }
  end

  # Checks rendered text only. Matching raw HTML also hits attributes, and the
  # random data-phx-session / csrf tokens occasionally contain e.g. "XP".
  defp refute_sheet(html) do
    text = visible_text(html)
    # Guard against an empty extraction making every refute pass.
    assert text =~ "Location"

    refute text =~ "Skill:"
    refute text =~ "Outcome:"
    refute text =~ "Roll:"
    refute text =~ "+LP"
    refute text =~ "Learning points"
    refute text =~ "insight +2"
    refute text =~ "you learned"
    refute text =~ ~r/\bXP\b/
    refute text =~ "learning_failures"
  end

  defp visible_text(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("body")
    |> LazyHTML.to_tree()
    |> LazyHTML.Tree.postwalk(fn
      {tag, _attrs, _children} when tag in ["script", "style", "template"] -> []
      node -> node
    end)
    |> LazyHTML.from_tree()
    |> LazyHTML.text(separator: " ")
  end
end
