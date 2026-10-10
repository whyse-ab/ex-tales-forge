defmodule TalesForge.Board.Transitions do
  @moduledoc """
  The idea board's card state machine (tales-forge-docs
  `docs/design-board-states.md`, approved by Fredrik 2026-10-10). Pure.

  The server checks every move with `allowed?/4`, and the board UI asks the
  same module which moves it can offer (`options/3`) and why a card cannot
  move (`blocker/2`).

  A card changes state only by an explicit move. A move that is not in this
  table is refused. Votes and comments do not move cards.

  States (the stored column names are on the left, the spec names in brackets):
  `ideas` (idea), `refining`, `check` (founder_check), `building`, `done`,
  `parked`.

  | From | To | Who | Gate | Wakes |
  |---|---|---|---|---|
  | ideas | refining | founder | at least 1 upvote and 0 downvotes | Case |
  | ideas | parked | founder | none | none |
  | refining | check | Case | refinement has verdict, cost and questions | founders (badge) |
  | refining | ideas | founder | none | none |
  | check | building | founder | all open questions answered or deferred | Bobby |
  | check | refining | founder | a comment that says what to change | Case |
  | check | parked | founder | none | none |
  | building | check | Bobby | linked PR needs founder approval | founders |
  | check (PR) | building | founder | Approve | Bobby (merge) |
  | building | done | the board (automatic), or Bobby | linked PR is on prod | founders (badge) |
  | building | refining | Bobby or founder | a comment with the blocker | Case |
  | parked | ideas | founder | none | none |
  | done | (none) | | done is final | |

  The card facts (`t:card/0`) come from `TalesForge.Board.facts/1`.
  """

  @typedoc "Who moves the card."
  @type actor :: {:founder, String.t()} | {:bot, :case | :bobby | :gentry | :board}

  @typedoc """
  Facts about the card that the gates need:

    * `up`, `down`: the number of upvotes and downvotes
    * `refined`: the refinement has a verdict, a cost and a list of questions
    * `open_questions`: the number of open questions with no answer and not deferred
    * `comment`: the comment that goes with the move (nil or blank for none)
    * `pr`: `nil` (no PR waits), `:awaiting` (a PR waits for a founder's OK)
      or `:approved` (a founder pressed Approve)
    * `pr_linked`: the card has a linked PR
    * `pr_on_prod`: `:ok` when the PR's merge commit is in the running prod
      release, `{:error, reason}` when not (nil: not checked)
  """
  @type card :: %{
          optional(:up) => non_neg_integer(),
          optional(:down) => non_neg_integer(),
          optional(:refined) => boolean(),
          optional(:open_questions) => non_neg_integer(),
          optional(:comment) => String.t() | nil,
          optional(:pr) => nil | :awaiting | :approved,
          optional(:pr_linked) => boolean(),
          optional(:pr_on_prod) => :ok | {:error, String.t()} | nil
        }

  @states ~w(ideas refining check building done parked)

  @labels %{
    "ideas" => "Ideas",
    "refining" => "Refining (Case)",
    "check" => "Founder check",
    "building" => "Building (Bobby)",
    "done" => "Done",
    "parked" => "Parked"
  }

  @doc """
  The states, in board order.

      iex> TalesForge.Board.Transitions.states()
      ["ideas", "refining", "check", "building", "done", "parked"]
  """
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  The display label of a state.

      iex> TalesForge.Board.Transitions.label("check")
      "Founder check"
  """
  @spec label(String.t()) :: String.t()
  def label(state), do: Map.get(@labels, state, state)

  @doc """
  `:ok` when `actor` may move the card from `from` to `to`, else
  `{:error, reason}`, a short sentence for the UI or the bot.

  Ideas → Refining: a founder, with at least 1 upvote and 0 downvotes.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{up: 1, down: 0}, "ideas", "refining", {:founder, "a@x"})
      :ok
      iex> T.allowed?(%{up: 0, down: 0}, "ideas", "refining", {:founder, "a@x"})
      {:error, "Needs an upvote."}
      iex> T.allowed?(%{up: 2, down: 1}, "ideas", "refining", {:founder, "a@x"})
      {:error, "Has a downvote. A founder must change their vote first."}
      iex> T.allowed?(%{up: 3, down: 0}, "ideas", "refining", {:bot, :case})
      {:error, "A founder moves this card."}

  Ideas → Parked: a founder, no gate.

      iex> TalesForge.Board.Transitions.allowed?(%{down: 1}, "ideas", "parked", {:founder, "a@x"})
      :ok
      iex> TalesForge.Board.Transitions.allowed?(%{}, "ideas", "parked", {:bot, :case})
      {:error, "A founder moves this card."}

  Refining → Founder check: Case, when the refinement has a verdict, a cost and questions.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{refined: true}, "refining", "check", {:bot, :case})
      :ok
      iex> T.allowed?(%{refined: false}, "refining", "check", {:bot, :case})
      {:error, "Waits for Case's refinement: verdict, cost and questions."}
      iex> T.allowed?(%{refined: true}, "refining", "check", {:founder, "a@x"})
      {:error, "Case moves this card when the refinement is complete."}

  Refining → Ideas: a founder, no gate.

      iex> TalesForge.Board.Transitions.allowed?(%{}, "refining", "ideas", {:founder, "a@x"})
      :ok
      iex> TalesForge.Board.Transitions.allowed?(%{}, "refining", "ideas", {:bot, :case})
      {:error, "A founder moves this card."}

  Founder check → Building: a founder, when every open question has an
  answer or is deferred (each question has its own answer box and Defer
  toggle on the full card). The move needs no comment.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{open_questions: 0}, "check", "building", {:founder, "a@x"})
      :ok
      iex> T.allowed?(%{open_questions: 2}, "check", "building", {:founder, "a@x"})
      {:error, "Answer or defer the 2 open questions."}
      iex> T.allowed?(%{open_questions: 1, comment: "a comment is not an answer"}, "check", "building", {:founder, "a@x"})
      {:error, "Answer or defer the 1 open question."}
      iex> T.allowed?(%{}, "check", "building", {:bot, :bobby})
      {:error, "A founder moves this card."}

  Founder check → Refining: a founder, with a comment that says what to change.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{comment: "Make it cheaper."}, "check", "refining", {:founder, "a@x"})
      :ok
      iex> T.allowed?(%{comment: " "}, "check", "refining", {:founder, "a@x"})
      {:error, "Write a comment that says what to change."}

  Founder check → Parked: a founder, no gate.

      iex> TalesForge.Board.Transitions.allowed?(%{}, "check", "parked", {:founder, "a@x"})
      :ok

  Building → Founder check: nobody. Founder check is only for the refined
  idea. A PR that waits for a founder's OK keeps the card in Building (see
  `pr_answer/2`).

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{pr: :awaiting}, "building", "check", {:bot, :bobby})
      {:error, "Founder check is for the refined idea. A PR waits for approval in Building."}
      iex> T.allowed?(%{pr: :awaiting}, "building", "check", {:founder, "a@x"})
      {:error, "Founder check is for the refined idea. A PR waits for approval in Building."}
      iex> T.allowed?(%{pr: :awaiting, open_questions: 0}, "check", "building", {:founder, "a@x"})
      :ok

  Building → Done: the board itself (`{:bot, :board}`, automatically after
  each prod boot, `TalesForge.Board.Workers.AutoDone`) or Bobby (the manual
  fallback), when the linked PR is on prod: its merge commit is
  in the running prod release (`pr_on_prod`, checked by
  `TalesForge.Board.OnProd` when Bobby moves the card).

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{pr_linked: true}, "building", "done", {:bot, :bobby})
      :ok
      iex> T.allowed?(%{pr_linked: false}, "building", "done", {:bot, :bobby})
      {:error, "Link the PR that is on prod first."}
      iex> T.allowed?(%{pr_linked: true, pr_on_prod: {:error, "PR #7 is not in the prod release yet."}}, "building", "done", {:bot, :bobby})
      {:error, "PR #7 is not in the prod release yet."}
      iex> T.allowed?(%{pr_linked: true, pr_on_prod: :ok}, "building", "done", {:bot, :board})
      :ok
      iex> T.allowed?(%{pr_linked: true, pr_on_prod: {:error, "PR #7 is not in the prod release yet."}}, "building", "done", {:bot, :board})
      {:error, "PR #7 is not in the prod release yet."}
      iex> T.allowed?(%{pr_linked: false}, "building", "done", {:bot, :board})
      {:error, "Link the PR that is on prod first."}
      iex> T.allowed?(%{pr_linked: true}, "building", "done", {:bot, :case})
      {:error, "Bobby moves this card when its PR is on prod."}
      iex> T.allowed?(%{pr_linked: true}, "building", "done", {:founder, "a@x"})
      {:error, "Bobby moves this card when its PR is on prod."}

  Building → Refining: Bobby or a founder, with a comment that names the blocker.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{comment: "The API has no search."}, "building", "refining", {:bot, :bobby})
      :ok
      iex> T.allowed?(%{comment: "Too slow."}, "building", "refining", {:founder, "a@x"})
      :ok
      iex> T.allowed?(%{}, "building", "refining", {:bot, :bobby})
      {:error, "Write a comment that names the blocker."}
      iex> T.allowed?(%{comment: "x"}, "building", "refining", {:bot, :case})
      {:error, "Bobby or a founder moves this card."}

  Parked → Ideas: a founder, no gate.

      iex> TalesForge.Board.Transitions.allowed?(%{}, "parked", "ideas", {:founder, "a@x"})
      :ok

  Done is final; moves not in the table are refused.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.allowed?(%{}, "done", "ideas", {:founder, "a@x"})
      {:error, "Done is final. Make a new card that links to this one."}
      iex> T.allowed?(%{}, "refining", "parked", {:founder, "a@x"})
      {:error, "Refining (Case) to Parked is not a move on the board."}
      iex> T.allowed?(%{}, "ideas", "ideas", {:founder, "a@x"})
      {:error, "The card is already there."}
  """
  @spec allowed?(card(), String.t(), String.t(), actor()) :: :ok | {:error, String.t()}
  def allowed?(_card, same, same, _actor), do: {:error, "The card is already there."}

  def allowed?(_card, "done", _to, _actor),
    do: {:error, "Done is final. Make a new card that links to this one."}

  def allowed?(card, "ideas", "refining", actor) do
    with :ok <- founder(actor) do
      cond do
        n(card, :down) > 0 -> {:error, "Has a downvote. A founder must change their vote first."}
        n(card, :up) < 1 -> {:error, "Needs an upvote."}
        true -> :ok
      end
    end
  end

  def allowed?(_card, "ideas", "parked", actor), do: founder(actor)

  def allowed?(card, "refining", "check", {:bot, :case}),
    do: need(card[:refined] == true, "Waits for Case's refinement: verdict, cost and questions.")

  def allowed?(_card, "refining", "check", _actor),
    do: {:error, "Case moves this card when the refinement is complete."}

  def allowed?(_card, "refining", "ideas", actor), do: founder(actor)

  def allowed?(card, "check", "building", actor) do
    with :ok <- founder(actor) do
      q = n(card, :open_questions)

      need(
        q == 0,
        "Answer or defer the #{q} open #{if q == 1, do: "question", else: "questions"}."
      )
    end
  end

  def allowed?(card, "check", "refining", actor) do
    with :ok <- founder(actor),
         do: need(comment?(card), "Write a comment that says what to change.")
  end

  def allowed?(_card, "check", "parked", actor), do: founder(actor)

  def allowed?(_card, "building", "check", _actor),
    do: {:error, "Founder check is for the refined idea. A PR waits for approval in Building."}

  def allowed?(card, "building", "done", {:bot, bot}) when bot in [:board, :bobby] do
    case {card[:pr_linked], card[:pr_on_prod]} do
      {true, {:error, reason}} -> {:error, reason}
      {true, _} -> :ok
      _ -> {:error, "Link the PR that is on prod first."}
    end
  end

  def allowed?(_card, "building", "done", _actor),
    do: {:error, "Bobby moves this card when its PR is on prod."}

  def allowed?(card, "building", "refining", actor) do
    case actor do
      a when a == {:bot, :bobby} or elem(a, 0) == :founder ->
        need(comment?(card), "Write a comment that names the blocker.")

      _ ->
        {:error, "Bobby or a founder moves this card."}
    end
  end

  def allowed?(_card, "parked", "ideas", actor), do: founder(actor)

  def allowed?(_card, from, to, _actor),
    do: {:error, "#{label(from)} to #{label(to)} is not a move on the board."}

  @doc """
  Can the actor Approve or Request changes on the card's PR? Only a founder,
  and only while the card is in Building with a PR that waits for an OK
  (`pr: :awaiting`). The card stays in Building. Approve wakes Bobby
  (`pr.approved`) to merge and ship; Request changes wakes him
  (`pr.changes_requested`) with the comment.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.pr_answer(%{pr: :awaiting}, "building", {:founder, "a@x"})
      :ok
      iex> T.pr_answer(%{pr: :awaiting}, "building", {:bot, :bobby})
      {:error, "Only a founder can answer a PR."}
      iex> T.pr_answer(%{pr: :approved}, "building", {:founder, "a@x"})
      {:error, "No PR waits for approval on this card."}
      iex> T.pr_answer(%{pr: :awaiting}, "check", {:founder, "a@x"})
      {:error, "A PR waits for approval in Building. This card is in Founder check."}
  """
  @spec pr_answer(card(), String.t(), actor()) :: :ok | {:error, String.t()}
  def pr_answer(_card, _column, {:bot, _}), do: {:error, "Only a founder can answer a PR."}

  def pr_answer(card, "building", _actor),
    do: need(card[:pr] == :awaiting, "No PR waits for approval on this card.")

  def pr_answer(_card, column, _actor),
    do: {:error, "A PR waits for approval in Building. This card is in #{label(column)}."}

  @doc """
  Who an event that is not a move wakes. An answer or a deferral of an
  open question (`question.answered`) wakes Case while the card is in
  Refining; in other columns the founders see it on the card.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> {T.event_wakes(:question_answered, "refining"), T.event_wakes(:question_answered, "check")}
      {[:case], []}
  """
  @spec event_wakes(atom(), String.t() | nil) :: [:case]
  def event_wakes(:question_answered, "refining"), do: [:case]
  def event_wakes(_event, _column), do: []

  @doc """
  Who a move wakes: `:case`, `:bobby`, and `:founders` (a badge on the board,
  no webhook). Empty for moves that wake nobody.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> {T.wakes("ideas", "refining"), T.wakes("check", "refining"), T.wakes("building", "refining")}
      {[:case], [:case], [:case]}
      iex> {T.wakes("check", "building"), T.wakes("refining", "check"), T.wakes("building", "check"), T.wakes("building", "done")}
      {[:bobby], [:founders], [:founders], [:founders]}
      iex> {T.wakes("ideas", "parked"), T.wakes("refining", "ideas"), T.wakes("parked", "ideas"), T.wakes("check", "parked")}
      {[], [], [], []}
  """
  @spec wakes(String.t(), String.t()) :: [:case | :bobby | :founders]
  def wakes(_from, "refining"), do: [:case]
  def wakes("check", "building"), do: [:bobby]

  def wakes(from, to)
      when {from, to} in [{"refining", "check"}, {"building", "check"}, {"building", "done"}],
      do: [:founders]

  def wakes(_from, _to), do: []

  @doc """
  Every other state with the answer of `allowed?/4` for `actor`, for the UI's
  "Move to" list and drag targets. A move that needs a comment counts as
  possible when the only gate is the comment (the form asks for it).

      iex> TalesForge.Board.Transitions.options(%{up: 0}, "ideas", {:founder, "a@x"})
      [{"refining", {:error, "Needs an upvote."}}, {"parked", :ok}]
      iex> TalesForge.Board.Transitions.options(%{}, "check", {:founder, "a@x"}) |> Enum.map(&elem(&1, 0))
      ["refining", "building", "parked"]
  """
  @spec options(card(), String.t(), actor()) :: [{String.t(), :ok | {:error, String.t()}}]
  def options(card, from, actor) do
    card = Map.put(card, :comment, "(comment)")

    for to <- @states, to != from, row?(from, to, actor) do
      {to, allowed?(card, from, to, actor)}
    end
  end

  @steps %{
    "ideas" => %{back: nil, forward: "refining", hold: "parked"},
    "refining" => %{back: "ideas", forward: "check", hold: nil},
    "check" => %{back: "refining", forward: "building", hold: "parked"},
    "building" => %{back: "refining", forward: "done", hold: nil},
    "parked" => %{back: nil, forward: "ideas", hold: nil},
    "done" => %{back: nil, forward: nil, hold: nil}
  }

  @typedoc "A move button on the full card."
  @type button :: %{
          kind: :back | :forward | :hold,
          to: String.t(),
          label: String.t(),
          answer: :ok | {:error, String.t()},
          needs_comment: boolean()
        }

  @doc """
  The Back, Forward and On hold buttons of a card in `from` for `actor`. Back
  is the previous state, Forward the next one, On hold is Parked (from
  Parked, Forward goes back to Ideas). Only the moves the actor may make are
  in the list. `answer` is `allowed?/4` for the card as it is (a failed gate
  disables the button and shows the reason). `needs_comment` is true when the
  move needs a comment: the button opens a comment box, and the gate is
  checked again with the comment.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.buttons(%{up: 0}, "ideas", {:founder, "a@x"})
      [%{kind: :forward, to: "refining", label: "Send to Refining", answer: {:error, "Needs an upvote."}, needs_comment: false},
       %{kind: :hold, to: "parked", label: "Put on hold", answer: :ok, needs_comment: false}]
      iex> T.buttons(%{open_questions: 0}, "check", {:founder, "a@x"}) |> Enum.map(&{&1.kind, &1.to, &1.needs_comment})
      [{:back, "refining", true}, {:forward, "building", false}, {:hold, "parked", false}]
      iex> T.buttons(%{}, "refining", {:founder, "a@x"}) |> Enum.map(&{&1.kind, &1.to})
      [{:back, "ideas"}]
      iex> T.buttons(%{}, "building", {:founder, "a@x"}) |> Enum.map(&{&1.kind, &1.to, &1.needs_comment})
      [{:back, "refining", true}]
      iex> T.buttons(%{}, "parked", {:founder, "a@x"}) |> Enum.map(&{&1.kind, &1.to})
      [{:forward, "ideas"}]
      iex> T.buttons(%{}, "done", {:founder, "a@x"})
      []
  """
  @spec buttons(card(), String.t(), actor()) :: [button()]
  def buttons(card, from, actor) do
    steps = Map.get(@steps, from, %{})

    for kind <- [:back, :forward, :hold],
        to = steps[kind],
        to != nil,
        row?(from, to, actor) do
      plain = Map.put(card, :comment, nil)
      answer = allowed?(Map.merge(card, %{comment: card[:comment]}), from, to, actor)

      needs_comment =
        allowed?(plain, from, to, actor) != :ok and
          allowed?(Map.put(card, :comment, "(comment)"), from, to, actor) == :ok and
          comment_gate?(allowed?(plain, from, to, actor))

      answer = if needs_comment, do: :ok, else: answer

      %{
        kind: kind,
        to: to,
        label: step_label(from, to),
        answer: answer,
        needs_comment: needs_comment
      }
    end
  end

  @doc """
  The button label of a move, named by its target step. The server and the
  UI share these.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> for {f, t} <- [{"ideas", "refining"}, {"ideas", "parked"}, {"refining", "check"}, {"refining", "ideas"}], do: T.step_label(f, t)
      ["Send to Refining", "Put on hold", "Send to Founder check", "Back to Ideas"]
      iex> for {f, t} <- [{"check", "building"}, {"check", "refining"}, {"check", "parked"}, {"building", "check"}], do: T.step_label(f, t)
      ["Start building", "Back to Refining", "Put on hold", "Send to Founder check"]
      iex> for {f, t} <- [{"building", "done"}, {"building", "refining"}, {"parked", "ideas"}], do: T.step_label(f, t)
      ["Mark as done", "Back to Refining", "Back to Ideas"]
  """
  @spec step_label(String.t(), String.t()) :: String.t()
  def step_label(_from, "parked"), do: "Put on hold"
  def step_label(_from, "building"), do: "Start building"
  def step_label(_from, "done"), do: "Mark as done"
  def step_label("ideas", "refining"), do: "Send to Refining"
  def step_label(_from, "refining"), do: "Back to Refining"
  def step_label(_from, "ideas"), do: "Back to Ideas"
  def step_label(_from, to), do: "Send to #{label(to)}"

  defp comment_gate?({:error, reason}), do: reason =~ "comment"
  defp comment_gate?(_), do: false

  # The actor may make this move when its gate is met.
  defp row?(from, to, actor) do
    open = %{up: 1, down: 0, refined: true, open_questions: 0, comment: "x", pr_linked: true}

    Enum.any?([:awaiting, :approved], fn pr ->
      allowed?(Map.put(open, :pr, pr), from, to, actor) == :ok
    end)
  end

  @doc """
  Why a card cannot take its next step, or nil when it can (or the next step
  is a bot's and its gate is met). The next steps: Ideas → Refining (a
  founder), Refining → Founder check (Case), Founder check → Building (a
  founder), Building → Done (Bobby). Shown on the card.

      iex> alias TalesForge.Board.Transitions, as: T
      iex> T.blocker(%{up: 0, down: 0}, "ideas")
      "Needs an upvote."
      iex> T.blocker(%{up: 1, down: 0}, "ideas")
      nil
      iex> T.blocker(%{refined: false}, "refining")
      "Waits for Case's refinement: verdict, cost and questions."
      iex> T.blocker(%{open_questions: 1}, "check")
      "Answer or defer the 1 open question."
      iex> T.blocker(%{}, "done")
      nil
  """
  @spec blocker(card(), String.t()) :: String.t() | nil
  def blocker(card, from) do
    step =
      %{
        "ideas" => {"refining", {:founder, "founder"}},
        "refining" => {"check", {:bot, :case}},
        "check" => {"building", {:founder, "founder"}},
        "building" => {"done", {:bot, :bobby}}
      }[from]

    with {to, actor} <- step,
         {:error, reason} <- allowed?(card, from, to, actor) do
      reason
    else
      _ -> nil
    end
  end

  @doc """
  The actor as a string for the move log (`founder email` or `bot:case`).

      iex> TalesForge.Board.Transitions.actor_name({:bot, :case})
      "bot:case"
  """
  @spec actor_name(actor()) :: String.t()
  def actor_name({:founder, email}), do: email
  def actor_name({:bot, bot}), do: "bot:#{bot}"

  defp founder({:founder, _}), do: :ok
  defp founder(_), do: {:error, "A founder moves this card."}

  defp need(true, _reason), do: :ok
  defp need(_, reason), do: {:error, reason}

  defp n(card, key), do: Map.get(card, key) || 0

  defp comment?(card), do: is_binary(card[:comment]) and String.trim(card[:comment]) != ""
end
