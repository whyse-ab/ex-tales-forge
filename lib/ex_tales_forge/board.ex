defmodule TalesForge.Board do
  @moduledoc """
  The founders' idea board on `/team` (tales-forge-docs
  `docs/design-idea-board.md`, decisions 2026-10-10). Production only
  (`TalesForge.AppRole.here?(:board)`).

  Founders add ideas and vote them up or down (one vote each, +1 or -1,
  changeable; `vote/3`); the Ideas column is ranked by
  `TalesForge.Board.Ranking`. Case refines, founders check and comment, a
  founder moves the card to Building (the OK, which writes the decision log
  entry), Bobby builds, Gentry checks and Bobby moves it to Done. Who may move
  what is `TalesForge.Board.Transitions`; every move is a `board_transitions` row,
  and what it sets off (bot pings, the decision commit) is queued in the same
  transaction (`TalesForge.Board.Events`).

  Changes are broadcast on `topic/0` as `{:board, :changed}`.
  """

  import Ecto.Query

  alias Ecto.Multi

  alias TalesForge.Board.{
    Answer,
    Approval,
    Comment,
    Events,
    Idea,
    Link,
    Mentions,
    Ping,
    Ranking,
    Transition,
    Transitions,
    Vote
  }

  alias TalesForge.Collab.Schemas.Decision
  alias TalesForge.Repo

  @topic "board:ideas"
  @gentry_pass "Gentry check: pass"

  @typedoc "Who acts (see `TalesForge.Board.Transitions`)."
  @type actor :: Transitions.actor()

  @typedoc "An error for the UI or a bot: a sentence or a changeset."
  @type error :: {:error, String.t() | Ecto.Changeset.t()}

  @doc "The PubSub topic of board changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the caller to board changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(TalesForge.PubSub, @topic)

  @doc """
  The whole board: a map of column => cards, with votes, comments, links and
  history loaded. Ideas are ranked (best first, with `:score` set fresh); the
  other columns are in the order the cards arrived there.
  """
  @spec board(DateTime.t()) :: %{String.t() => [Idea.t()]}
  def board(now \\ DateTime.utc_now()) do
    ideas = Idea |> Repo.all() |> preload_all()
    grouped = Enum.group_by(ideas, & &1.column)

    Map.new(Idea.columns(), fn column ->
      cards = Map.get(grouped, column, [])
      {column, order(column, cards, now)}
    end)
  end

  @doc "The ranked Ideas column (best first), with fresh scores."
  @spec ranked_ideas(DateTime.t()) :: [Idea.t()]
  def ranked_ideas(now \\ DateTime.utc_now()) do
    from(i in Idea, where: i.column == "ideas")
    |> Repo.all()
    |> preload_all()
    |> then(&order("ideas", &1, now))
  end

  # The backlog: net votes, then total votes, both descending; then the
  # oldest card first.
  defp order("ideas", cards, now) do
    cards
    |> Enum.map(fn idea ->
      %{idea | score: Ranking.score(net_votes(idea), Ranking.age_days(idea.inserted_at, now))}
    end)
    |> Enum.sort_by(fn idea ->
      {-net_votes(idea), -length(idea.votes), DateTime.to_unix(idea.inserted_at, :microsecond)}
    end)
  end

  defp order(_column, cards, _now), do: Enum.sort_by(cards, &entered_at/1, {:asc, DateTime})

  defp entered_at(idea) do
    case Enum.max_by(idea.transitions, & &1.inserted_at, DateTime, fn -> nil end) do
      nil -> idea.inserted_at
      t -> t.inserted_at
    end
  end

  defp preload_all(query_or_ideas) do
    Repo.preload(query_or_ideas,
      votes: [],
      comments: from(c in Comment, order_by: [asc: c.inserted_at, asc: c.id]),
      links: from(l in Link, order_by: [asc: l.inserted_at]),
      transitions: from(t in Transition, order_by: [asc: t.inserted_at, asc: t.id]),
      approvals: from(a in Approval, order_by: [asc: a.inserted_at, asc: a.id]),
      answers: []
    )
  end

  @doc "The card's address on production's /team (its `#idea-<id>` anchor)."
  @spec url(Idea.t()) :: String.t()
  def url(%Idea{id: id}),
    do: String.trim_trailing(TalesForge.AppRole.base_url(:production), "/") <> "/team#idea-" <> id

  @doc "One card with everything loaded; raises when missing."
  @spec get_idea!(Ecto.UUID.t()) :: Idea.t()
  def get_idea!(id), do: Idea |> Repo.get!(id) |> preload_all()

  @doc "One card with everything loaded, or nil (also for a malformed id)."
  @spec get_idea(String.t()) :: Idea.t() | nil
  def get_idea(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Idea |> Repo.get(uuid) |> then(&(&1 && preload_all(&1)))
      :error -> nil
    end
  end

  @doc "The net votes of a card (votes loaded)."
  @spec net_votes(Idea.t()) :: integer()
  def net_votes(%Idea{votes: votes}) when is_list(votes),
    do: votes |> Enum.map(& &1.value) |> Enum.sum()

  @doc "True when any founder has a -1 vote on the card (votes loaded): it can't go to Building."
  @spec downvoted?(Idea.t()) :: boolean()
  def downvoted?(%Idea{votes: votes}), do: Enum.any?(votes, &(&1.value == -1))

  @doc "The vote of `founder` on the card (votes loaded): 1, -1 or nil."
  @spec vote_of(Idea.t(), String.t()) :: 1 | -1 | nil
  def vote_of(%Idea{votes: votes}, founder) do
    founder = normalize(founder)
    Enum.find_value(votes, &(&1.founder == founder && &1.value))
  end

  @doc "True when Gentry has passed the card (a comment starting #{inspect(@gentry_pass)})."
  @spec gentry_ok?(Idea.t()) :: boolean()
  def gentry_ok?(%Idea{comments: comments}),
    do:
      Enum.any?(
        comments,
        &(&1.author == "bot:gentry" and String.starts_with?(&1.body, @gentry_pass))
      )

  @doc "The text a Gentry comment starts with when the check passed."
  @spec gentry_pass() :: String.t()
  def gentry_pass, do: @gentry_pass

  @doc "Adds an idea to the Ideas column, by `founder`."
  @spec create_idea(String.t(), map()) :: {:ok, Idea.t()} | error()
  def create_idea(founder, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    Multi.new()
    |> Multi.insert(
      :idea,
      Idea.create_changeset(%Idea{}, %{
        "title" => attrs["title"],
        "body" => attrs["body"] || "",
        "author" => normalize(founder)
      })
    )
    |> Multi.insert(:transition, fn %{idea: idea} ->
      Transition.changeset(%Transition{}, %{
        idea_id: idea.id,
        to: "ideas",
        actor: normalize(founder)
      })
    end)
    |> run()
  end

  @doc """
  Sets `founder`'s vote on the card to `value` (1 or -1). A -1 needs a
  `reason`, saved with the vote. Voting the same value again takes the vote
  back (and its reason); the other value changes it. Only on cards in Ideas,
  Refining or Founder check. Votes do not move cards and wake nobody.
  """
  @spec vote(Idea.t(), String.t(), 1 | -1, String.t() | nil) :: {:ok, Idea.t()} | error()
  def vote(idea, founder, value, reason \\ nil)

  def vote(%Idea{} = idea, founder, value, reason) when value in [1, -1] do
    founder = normalize(founder)
    reason = if is_binary(reason), do: String.trim(reason), else: nil

    if idea.column in ~w(ideas refining check) do
      result =
        case Repo.get_by(Vote, idea_id: idea.id, founder: founder) do
          %Vote{value: ^value} = vote ->
            Repo.delete(vote)

          %Vote{} = vote ->
            vote |> Vote.changeset(%{value: value, reason: reason}) |> Repo.update()

          nil ->
            %Vote{}
            |> Vote.changeset(%{idea_id: idea.id, founder: founder, value: value, reason: reason})
            |> Repo.insert()
        end

      case result do
        {:ok, _} ->
          broadcast()
          {:ok, get_idea!(idea.id)}

        {:error, %Ecto.Changeset{errors: [{:reason, _} | _]}} ->
          {:error, "A downvote needs a reason. Write what needs work."}

        other ->
          other
      end
    else
      {:error, "Votes are closed once a card is in #{Transitions.label(idea.column)}."}
    end
  end

  def vote(_idea, _founder, _value, _reason), do: {:error, "A vote is +1 or -1."}

  @doc """
  Adds a comment by `author` (a founder email or `bot:<name>`). `@case`,
  `@bobby`, `@gentry` wake that bot. `@fredrik`, `@hakan`, ... and
  `@founders` add an unread ping for each founder named, except the author
  (see `TalesForge.Board.Mentions`).
  """
  @spec add_comment(Idea.t(), String.t(), String.t()) :: {:ok, Idea.t()} | error()
  def add_comment(%Idea{} = idea, author, body) do
    author = normalize(author)
    changeset = Comment.changeset(%Comment{}, %{idea_id: idea.id, author: author, body: body})
    %{bots: bots, founders: founders} = Mentions.parse(body)
    founders = founders -- [Mentions.handle_for(author)]

    Multi.new()
    |> Multi.insert(:comment, changeset)
    |> Multi.run(:pings, fn repo, %{comment: comment} ->
      now = DateTime.utc_now()

      rows =
        for h <- founders,
            do: %{
              id: Ecto.UUID.generate(),
              idea_id: idea.id,
              comment_id: comment.id,
              handle: h,
              author: author,
              inserted_at: now
            }

      {n, _} = repo.insert_all(Ping, rows)
      {:ok, n}
    end)
    |> then(fn multi ->
      Enum.reduce(bots, multi, fn bot, acc ->
        Events.add(acc, :mention, idea, %{bot: bot, body: body, author: author})
      end)
    end)
    |> run(idea.id)
  end

  @doc """
  The bots mentioned in a comment.

      iex> TalesForge.Board.mentions("@Case can you look? cc @gentry, not @bobbyx")
      [:case, :gentry]
  """
  @spec mentions(String.t()) :: [:case | :bobby | :gentry]
  def mentions(body), do: Mentions.parse(body, []).bots

  @doc """
  The unread pings of a founder (by email), one entry for each card, newest
  first: `%{idea_id, title, count, from, at}`.
  """
  @spec unread_pings(String.t()) :: [map()]
  def unread_pings(email) do
    case Mentions.handle_for(email) do
      nil ->
        []

      handle ->
        from(p in Ping,
          join: i in Idea,
          on: i.id == p.idea_id,
          where: p.handle == ^handle and is_nil(p.read_at),
          order_by: [desc: p.inserted_at],
          select: {i.id, i.title, p.author, p.inserted_at}
        )
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0))
        |> Enum.map(fn {id, [{_, title, from, at} | _] = all} ->
          %{idea_id: id, title: title, count: length(all), from: from, at: at}
        end)
        |> Enum.sort_by(& &1.at, {:desc, DateTime})
    end
  end

  @doc "Marks a founder's pings on a card as read (they opened the card)."
  @spec read_pings(String.t(), String.t()) :: non_neg_integer()
  def read_pings(idea_id, email) do
    with handle when is_binary(handle) <- Mentions.handle_for(email),
         {n, _} when n > 0 <-
           from(p in Ping,
             where: p.idea_id == ^idea_id and p.handle == ^handle and is_nil(p.read_at)
           )
           |> Repo.update_all(set: [read_at: DateTime.utc_now()]) do
      broadcast()
      n
    else
      _ -> 0
    end
  end

  @doc """
  Adds a link (`kind`: pr, playtest, decision, doc, other). Only bots add
  links (`added_by` is `bot:<name>`, through the bot API): Bobby the PR,
  Gentry or Bobby the playtest run. Links wake nobody.
  """
  @spec add_link(Idea.t(), String.t(), map()) :: {:ok, Idea.t()} | error()
  def add_link(%Idea{} = idea, "bot:" <> _ = added_by, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    changeset =
      Link.changeset(%Link{}, %{
        idea_id: idea.id,
        kind: attrs["kind"],
        url: attrs["url"],
        label: attrs["label"],
        added_by: added_by
      })

    Multi.new()
    |> Multi.insert(:link, changeset)
    |> run(idea.id)
  end

  def add_link(%Idea{}, _added_by, _attrs),
    do: {:error, "Bots add the links: Bobby the PR, Gentry or Bobby the playtest run."}

  @refinement_keys ~w(details open_questions rough_cost verdict)
  @verdicts ~w(feasible feasible_with_caveats not_feasible)
  @costs ~w(S M L)

  @doc """
  Case's refinement of a card in Refining: `details` (text), `open_questions`
  (a list of strings), `rough_cost` (S, M or L) and `verdict` (feasible,
  feasible_with_caveats or not_feasible). Merged into what is there.
  """
  @spec refine(Idea.t(), map()) :: {:ok, Idea.t()} | error()
  def refine(%Idea{column: "refining"} = idea, attrs) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.take(@refinement_keys)
    merged = Map.merge(idea.refinement || %{}, attrs)

    with :ok <- valid_refinement(merged) do
      idea |> Idea.update_changeset(%{refinement: merged}) |> Repo.update() |> after_update()
    end
  end

  def refine(%Idea{}, _attrs), do: {:error, "Only a card in Refining can be refined."}

  defp valid_refinement(r) do
    cond do
      Map.has_key?(r, "open_questions") and not is_list(r["open_questions"]) ->
        {:error, "open_questions must be a list of strings."}

      Map.has_key?(r, "rough_cost") and r["rough_cost"] not in @costs ->
        {:error, "rough_cost must be S, M or L."}

      Map.has_key?(r, "verdict") and r["verdict"] not in @verdicts ->
        {:error, "verdict must be feasible, feasible_with_caveats or not_feasible."}

      true ->
        :ok
    end
  end

  @doc "True when the refinement has a verdict, a rough cost and its open questions (a list, may be empty)."
  @spec refined?(Idea.t()) :: boolean()
  def refined?(%Idea{refinement: r}) do
    is_list(r["open_questions"]) and r["rough_cost"] in @costs and r["verdict"] in @verdicts
  end

  @doc """
  The facts about a card that `TalesForge.Board.Transitions` needs (votes,
  links, approvals and refinement loaded), with the move's `comment`.
  """
  @spec facts(Idea.t(), String.t() | nil) :: Transitions.card()
  def facts(%Idea{} = idea, comment \\ nil) do
    %{
      up: Enum.count(idea.votes, &(&1.value == 1)),
      down: Enum.count(idea.votes, &(&1.value == -1)),
      refined: refined?(idea),
      open_questions: idea |> questions() |> Enum.count(fn {_q, a} -> not Answer.settled?(a) end),
      comment: comment,
      pr: pr_state(idea),
      pr_linked: idea.pr_number != nil or Enum.any?(idea.links, &(&1.kind == "pr"))
    }
  end

  @doc """
  The open questions of Case's refinement, each with its answer (or nil),
  in Case's order (answers loaded).
  """
  @spec questions(Idea.t()) :: [{String.t(), Answer.t() | nil}]
  def questions(%Idea{} = idea) do
    answers = Map.new(idea.answers, &{&1.question, &1})

    (idea.refinement || %{})["open_questions"]
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(&{&1, answers[&1]})
  end

  @doc """
  A founder answers one open question (`attrs`: `"answer"`), or defers it
  (`"deferred"`: true / false). Any founder may defer or undefer; an answer
  can be changed only by the founder who wrote it. Writes a line in the
  card's history; while the card is in Refining it wakes Case
  (`question.answered`, see `TalesForge.Board.Transitions.event_wakes/2`).
  """
  @spec answer_question(Idea.t(), String.t(), String.t(), map()) :: {:ok, Idea.t()} | error()
  def answer_question(%Idea{}, "bot:" <> _, _question, _attrs),
    do: {:error, "Founders answer the open questions."}

  def answer_question(%Idea{} = idea, founder, question, attrs) do
    idea = get_idea!(idea.id)
    founder = normalize(founder)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    now = DateTime.utc_now()

    with {^question, current} <-
           Enum.find(questions(idea), {:error, nil}, fn {q, _} -> q == question end),
         {:ok, change, note} <- answer_change(current, founder, attrs, now, question) do
      row = current || %Answer{idea_id: idea.id, question: question}

      Multi.new()
      |> Multi.insert_or_update(:answer, Answer.changeset(row, change))
      |> Multi.insert(
        :transition,
        Transition.changeset(%Transition{}, %{
          idea_id: idea.id,
          from: idea.column,
          to: idea.column,
          actor: founder,
          note: note
        })
      )
      |> Events.add(:question_answered, idea, %{
        actor: founder,
        from: idea.column,
        to: idea.column,
        column: idea.column,
        question: %{
          "text" => question,
          "answer" => Map.get(change, :answer, current && current.answer),
          "deferred" => Map.get(change, :deferred, (current && current.deferred) || false),
          "by" => founder
        }
      })
      |> run(idea.id)
    else
      :unchanged -> {:ok, idea}
      {:error, nil} -> {:error, "That question is not on the card any more."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp answer_change(current, founder, %{"deferred" => d}, now, question) do
    deferred = d in [true, "true"]

    if current && current.deferred == deferred,
      do: :unchanged,
      else: defer_change(deferred, founder, now, question)
  end

  defp answer_change(current, founder, %{"answer" => text}, now, question) do
    text = text |> to_string() |> String.trim()

    cond do
      text == "" ->
        {:error, "Write an answer, or defer the question."}

      current && current.answered_by == founder && current.answer == text ->
        :unchanged

      current && current.answered_by not in [nil, founder] ->
        {:error,
         "#{current.answered_by} answered this question. Only they can change the answer. Write a comment to discuss it."}

      true ->
        {:ok, %{answer: text, answered_by: founder, answered_at: now},
         "Answered: #{question} Answer: #{text}"}
    end
  end

  defp answer_change(_current, _founder, _attrs, _now, _question),
    do: {:error, "Write an answer, or defer the question."}

  defp defer_change(deferred, founder, now, question) do
    if deferred,
      do:
        {:ok, %{deferred: true, deferred_by: founder, deferred_at: now}, "Deferred: #{question}"},
      else:
        {:ok, %{deferred: false, deferred_by: nil, deferred_at: nil},
         "Open again (not deferred): #{question}"}
  end

  @doc """
  The card's PR number (links loaded): the one Bobby linked for approval,
  else the first `pr` link that points at a pull request; nil for none.
  """
  @spec pr_number_of(Idea.t()) :: pos_integer() | nil
  def pr_number_of(%Idea{pr_number: n}) when is_integer(n), do: n

  def pr_number_of(idea) do
    idea.links
    |> Enum.filter(&(&1.kind == "pr"))
    |> Enum.find_value(fn l ->
      case Regex.run(~r{/pull/(\d+)}, l.url) do
        [_, n] -> String.to_integer(n)
        _ -> nil
      end
    end)
  end

  # :awaiting while the card's PR (at its current head sha) has no Approve.
  defp pr_state(%Idea{pr_number: nil}), do: nil

  defp pr_state(idea) do
    approved? =
      Enum.any?(
        idea.approvals,
        &(&1.decision == "approved" and &1.pr_number == idea.pr_number and
            &1.head_sha == idea.pr_head_sha)
      )

    if approved?, do: :approved, else: :awaiting
  end

  @doc """
  Moves a card to `to` for `actor`, if `TalesForge.Board.Transitions` allows it,
  with an optional `note` for the history. Writes the transition and queues
  what the move sets off in the same transaction.
  """
  @spec move(Idea.t(), actor(), String.t(), String.t() | nil) :: {:ok, Idea.t()} | error()
  def move(%Idea{} = idea, actor, to, note \\ nil) do
    idea = get_idea!(idea.id)

    facts = facts(idea, note)

    facts =
      if idea.column == "building" and to == "done" and facts.pr_linked,
        do: Map.put(facts, :pr_on_prod, TalesForge.Board.OnProd.check(pr_number_of(idea))),
        else: facts

    with :ok <- Transitions.allowed?(facts, idea.column, to, actor) do
      Multi.new()
      |> Multi.update(:idea, Idea.update_changeset(idea, %{column: to}))
      |> Multi.insert(
        :transition,
        Transition.changeset(%Transition{}, %{
          idea_id: idea.id,
          from: idea.column,
          to: to,
          actor: Transitions.actor_name(actor),
          note: note
        })
      )
      |> add_move_events(idea, to, actor)
      |> run(idea.id)
    end
  end

  defp add_move_events(multi, idea, to, actor) do
    extra = %{from: idea.column, to: to, actor: Transitions.actor_name(actor)}

    case {idea.column, to} do
      {"ideas", "refining"} -> Events.add(multi, :idea_to_refining, idea, extra)
      {_, "refining"} -> Events.add(multi, :idea_back_to_refining, idea, extra)
      {_, "check"} -> Events.add(multi, :idea_to_check, idea, extra)
      {_, "building"} -> Events.add(multi, :idea_to_building, idea, extra)
      {_, "done"} -> Events.add(multi, :idea_to_done, idea, extra)
      _ -> multi
    end
  end

  @doc "Records the decision log commit of a card (set once; idempotent)."
  @spec record_decision(Idea.t(), String.t(), String.t(), String.t()) :: {:ok, Idea.t()} | error()
  def record_decision(%Idea{} = idea, slug, sha, url) do
    idea = get_idea!(idea.id)

    if idea.decision_sha do
      {:ok, idea}
    else
      Multi.new()
      |> Multi.update(
        :idea,
        Idea.update_changeset(idea, %{decision_sha: sha, decision_slug: slug})
      )
      |> Multi.insert(
        :link,
        Link.changeset(%Link{}, %{
          idea_id: idea.id,
          kind: "decision",
          url: url,
          label: "Decision log",
          added_by: "board"
        }),
        on_conflict: :nothing
      )
      |> Multi.insert(
        :transition,
        Transition.changeset(%Transition{}, %{
          idea_id: idea.id,
          from: idea.column,
          to: idea.column,
          actor: "board",
          note: "Decision log entry written: #{sha}"
        })
      )
      |> run(idea.id)
    end
  end

  @doc """
  Imports the open Collab decisions (`/admin/founders/decisions`, status open
  or discussing) as Ideas, once each (`collab_decision_id`), with their
  comments. Afterwards the decision queue is read-only
  (`TalesForge.Collab.read_only?/0`). Returns how many were imported.
  """
  @spec import_collab() :: {:ok, non_neg_integer()}
  def import_collab do
    imported =
      from(i in Idea, where: not is_nil(i.collab_decision_id), select: i.collab_decision_id)

    decisions =
      from(d in Decision,
        where: d.status in ["open", "discussing"] and d.id not in subquery(imported),
        order_by: [asc: d.rank, asc: d.slug],
        preload: [:comments]
      )
      |> Repo.all()

    Repo.transaction(fn ->
      Enum.each(decisions, &import_decision/1)
    end)

    broadcast()
    {:ok, length(decisions)}
  end

  defp import_decision(decision) do
    body =
      [
        decision.body,
        options(decision.options),
        "Imported from the decision queue (#{decision.slug})."
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n")

    idea =
      %Idea{}
      |> Idea.create_changeset(%{
        title: String.slice(decision.title, 0, 160),
        body: body,
        author: "import",
        collab_decision_id: decision.id
      })
      |> Repo.insert!()

    Repo.insert!(
      Transition.changeset(%Transition{}, %{
        idea_id: idea.id,
        to: "ideas",
        actor: "import",
        note: "From the decision queue: #{decision.slug}"
      })
    )

    Enum.each(decision.comments, fn c ->
      Repo.insert!(
        Comment.changeset(%Comment{}, %{idea_id: idea.id, author: c.author_email, body: c.body})
      )
    end)
  end

  defp options([]), do: nil
  defp options(options), do: "Options:\n" <> Enum.map_join(options, "\n", &("- " <> &1))

  @doc "True once the open Collab decisions have been imported."
  @spec collab_imported?() :: boolean()
  def collab_imported?, do: TalesForge.Collab.read_only?()

  @doc """
  Bobby puts a PR up for a founder's merge OK (decision 2026-10-10; only
  normal-lane PRs, fast-lane PRs need no OK). `attrs`: `number`, `url`,
  `head_sha`, `player_note` (one line: what changes for players), and either
  `idea_id` (an existing card) or `title` (a new card, which Bobby makes in
  Building). The card gets the PR fields and a `pr` link and moves Building →
  Founder check (`TalesForge.Board.Transitions`), with a line in the move log.
  Linking the same PR again while the card is in Founder check updates the head
  sha and note; a new head sha needs a new Approve.
  """
  @spec link_pr(map()) :: {:ok, Idea.t()} | error()
  def link_pr(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, number} <- pr_number(attrs["number"]),
         :ok <- need_text(attrs["url"], "url"),
         :ok <- need_text(attrs["head_sha"], "head_sha"),
         :ok <- need_text(attrs["player_note"], "player_note"),
         {:ok, idea} <- pr_card(attrs, number) do
      put_pr(idea, number, attrs)
    end
  end

  defp pr_number(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp pr_number(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> {:ok, i}
      _ -> {:error, "number must be the PR number."}
    end
  end

  defp pr_number(_), do: {:error, "number must be the PR number."}

  defp need_text(v, name) do
    if is_binary(v) and String.trim(v) != "", do: :ok, else: {:error, "#{name} is required."}
  end

  defp pr_card(%{"idea_id" => id}, _number) when is_binary(id) and id != "" do
    case get_idea(id) do
      nil -> {:error, "No such card."}
      idea -> {:ok, idea}
    end
  end

  defp pr_card(attrs, number) do
    case Repo.one(from i in Idea, where: i.pr_number == ^number, limit: 1) do
      %Idea{} = idea ->
        {:ok, get_idea!(idea.id)}

      nil ->
        title = attrs["title"] |> to_string() |> String.trim()
        title = if title == "", do: "PR ##{number}", else: title
        create_building_card(title, attrs["player_note"])
    end
  end

  # Bobby builds a PR that has no card yet: a new card, made in Building.
  defp create_building_card(title, body) do
    Multi.new()
    |> Multi.insert(
      :idea,
      Idea.create_changeset(%Idea{}, %{"title" => title, "body" => body, "author" => "bot:bobby"})
    )
    |> Multi.update(:building, fn %{idea: idea} ->
      Idea.update_changeset(idea, %{column: "building"})
    end)
    |> Multi.insert(:transition, fn %{idea: idea} ->
      Transition.changeset(%Transition{}, %{
        idea_id: idea.id,
        to: "building",
        actor: "bot:bobby",
        note: "Bobby made this card for a PR."
      })
    end)
    |> run()
  end

  defp put_pr(%Idea{column: "check", pr_number: number} = idea, number, attrs),
    do: write_pr(idea, number, attrs, nil)

  defp put_pr(%Idea{column: "building"} = idea, number, attrs) do
    with :ok <-
           Transitions.allowed?(%{pr: :awaiting}, "building", "check", {:bot, :bobby}),
         do: write_pr(idea, number, attrs, "check")
  end

  defp put_pr(idea, _number, _attrs),
    do:
      {:error,
       "Bobby links a PR to a card in Building. This card is in #{Transitions.label(idea.column)}."}

  defp write_pr(idea, number, attrs, to) do
    note = String.trim(attrs["player_note"])

    Multi.new()
    |> Multi.update(
      :idea,
      Idea.update_changeset(idea, %{
        column: to || idea.column,
        pr_number: number,
        pr_url: attrs["url"],
        pr_head_sha: String.trim(attrs["head_sha"]),
        player_note: note
      })
    )
    |> Multi.insert(:transition, fn _ ->
      Transition.changeset(%Transition{}, %{
        idea_id: idea.id,
        from: idea.column,
        to: "check",
        actor: "bot:bobby",
        note: "PR ##{number} (#{short(attrs["head_sha"])}) waits for a founder's OK: #{note}"
      })
    end)
    |> then(fn multi ->
      if to,
        do:
          Events.add(multi, :idea_to_check, idea, %{from: idea.column, to: to, actor: "bot:bobby"}),
        else: multi
    end)
    |> then(fn multi ->
      if Enum.any?(idea.links, &(&1.kind == "pr" and &1.url == attrs["url"])),
        do: multi,
        else:
          Multi.insert(
            multi,
            :link,
            Link.changeset(%Link{}, %{
              idea_id: idea.id,
              kind: "pr",
              url: attrs["url"],
              label: "PR ##{number}",
              added_by: "bot:bobby"
            })
          )
    end)
    |> run(idea.id)
  end

  @doc """
  A founder answers the PR on a card: `:approve` or `:request_changes`, with
  an optional `comment`. Records who, when, the PR number and its head sha
  (`TalesForge.Board.Approval`), writes a line in the history and wakes Bobby
  (`pr.approved` / `pr.changes_requested`). Approving also moves the card from
  Founder check to Building (`TalesForge.Board.Transitions`: Approve is the
  gate). Request changes keeps the card in Founder check.
  """
  @spec answer_pr(Idea.t(), String.t(), :approve | :request_changes, String.t() | nil) ::
          {:ok, Idea.t()} | error()
  def answer_pr(%Idea{pr_number: nil}, _founder, _answer, _comment),
    do: {:error, "No PR waits on this card."}

  def answer_pr(%Idea{} = idea, founder, answer, comment)
      when answer in [:approve, :request_changes] do
    idea = get_idea!(idea.id)
    founder = normalize(founder)
    comment = comment |> to_string() |> String.trim()
    approve? = answer == :approve
    to = if approve?, do: "building", else: idea.column

    with :ok <- answer_allowed(idea, founder, approve?) do
      decision = if approve?, do: "approved", else: "changes_requested"
      label = if approve?, do: "Approved", else: "Changes requested on"

      extra = %{
        actor: founder,
        from: idea.column,
        to: to,
        pr: %{
          "number" => idea.pr_number,
          "url" => idea.pr_url,
          "head_sha" => idea.pr_head_sha
        },
        approver: founder,
        comment: comment
      }

      Multi.new()
      |> Multi.insert(
        :approval,
        Approval.changeset(%Approval{}, %{
          idea_id: idea.id,
          decision: decision,
          founder: founder,
          pr_number: idea.pr_number,
          head_sha: idea.pr_head_sha,
          comment: comment
        })
      )
      |> then(fn m ->
        if approve?,
          do: Multi.update(m, :idea, Idea.update_changeset(idea, %{column: to})),
          else: m
      end)
      |> Multi.insert(
        :transition,
        Transition.changeset(%Transition{}, %{
          idea_id: idea.id,
          from: idea.column,
          to: to,
          actor: founder,
          note:
            "#{label} PR ##{idea.pr_number} (#{short(idea.pr_head_sha)})" <>
              if(comment == "", do: "", else: ": " <> comment)
        })
      )
      |> Events.add(if(approve?, do: :pr_approved, else: :pr_changes_requested), idea, extra)
      |> run(idea.id)
    end
  end

  defp answer_allowed(idea, founder, approve?) do
    cond do
      String.starts_with?(founder, "bot:") ->
        {:error, "Only a founder can answer a PR."}

      idea.column != "check" ->
        {:error,
         "The PR waits in Founder check; this card is in #{Transitions.label(idea.column)}."}

      approve? ->
        idea
        |> facts()
        |> Map.put(:pr, :approved)
        |> Transitions.allowed?("check", "building", {:founder, founder})

      true ->
        :ok
    end
  end

  defp short(nil), do: "no sha"
  defp short(sha) when not is_binary(sha), do: "no sha"
  defp short(sha), do: String.slice(sha, 0, 7)

  defp run(multi, idea_id \\ nil) do
    case Repo.transaction(multi) do
      {:ok, changes} ->
        broadcast()
        id = idea_id || changes[:idea].id
        {:ok, get_idea!(id)}

      {:error, _step, %Ecto.Changeset{} = changeset, _} ->
        {:error, changeset}

      {:error, _step, reason, _} ->
        {:error, inspect(reason)}
    end
  end

  defp after_update({:ok, idea}) do
    broadcast()
    {:ok, get_idea!(idea.id)}
  end

  defp after_update(error), do: error

  defp broadcast, do: Phoenix.PubSub.broadcast(TalesForge.PubSub, @topic, {:board, :changed})

  defp normalize("bot:" <> _ = bot), do: bot
  defp normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
end
