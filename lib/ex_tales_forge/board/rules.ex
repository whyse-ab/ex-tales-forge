defmodule TalesForge.Board.Rules do
  @moduledoc """
  Who may move a card where (tales-forge-docs `docs/design-idea-board.md`,
  questions resolved 2026-10-10). Actors are a founder (`{:founder, email}`,
  any signed-in team member) or a bot (`{:bot, :case | :bobby | :gentry}`).

  | From → To | Who |
  |---|---|
  | Ideas → Refining | a founder; Case only for an idea with real support |
  | Refining → Founder check | Case, with a complete refinement |
  | Founder check → Refining | a founder |
  | Founder check → Building | a founder (the OK), not while any vote is -1 |
  | Building → Done | Bobby, with a PR and a playtest link, after Gentry's check |
  | Ideas, Refining, Founder check ↔ Parked | a founder |

  Pure: the facts about the card come in as `facts`.
  """

  @typedoc "Who acts."
  @type actor :: {:founder, String.t()} | {:bot, :case | :bobby | :gentry}

  @typedoc "Facts about the card that some moves need."
  @type facts :: %{
          optional(:pullable) => boolean(),
          optional(:refined) => boolean(),
          optional(:downvoted) => boolean(),
          optional(:pr_and_playtest) => boolean(),
          optional(:gentry_ok) => boolean()
        }

  @labels %{
    "ideas" => "Ideas",
    "refining" => "Refining (Case)",
    "check" => "Founder check",
    "building" => "Building (Bobby)",
    "done" => "Done",
    "parked" => "Parked"
  }

  @doc """
  The display label of a column.

      iex> TalesForge.Board.Rules.label("check")
      "Founder check"
  """
  @spec label(String.t()) :: String.t()
  def label(column), do: Map.get(@labels, column, column)

  @doc """
  `:ok` when `actor` may move a card from `from` to `to`, else
  `{:error, reason}` with a sentence for the UI or the bot.

      iex> TalesForge.Board.Rules.check({:founder, "a@x"}, "check", "building", %{downvoted: false})
      :ok
      iex> TalesForge.Board.Rules.check({:founder, "a@x"}, "check", "building", %{downvoted: true})
      {:error, "A founder has voted -1 on this idea. Talk it through first."}
      iex> TalesForge.Board.Rules.check({:bot, :bobby}, "check", "building", %{})
      {:error, "Only a founder can move a card to Building."}
  """
  @spec check(actor(), String.t(), String.t(), facts()) :: :ok | {:error, String.t()}
  def check(_actor, same, same, _facts), do: {:error, "The card is already there."}

  def check({:founder, _}, "ideas", "refining", _), do: :ok

  def check({:bot, :case}, "ideas", "refining", facts),
    do: need(facts[:pullable], "Case pulls only ideas with score above 0.3 in the top 3.")

  def check({:bot, :case}, "refining", "check", facts),
    do:
      need(
        facts[:refined],
        "Fill in the refinement first: details, open questions, rough cost and verdict."
      )

  def check({:founder, _}, "check", "refining", _), do: :ok

  def check({:founder, _}, "check", "building", facts) do
    if facts[:downvoted],
      do: {:error, "A founder has voted -1 on this idea. Talk it through first."},
      else: :ok
  end

  def check(_actor, "check", "building", _),
    do: {:error, "Only a founder can move a card to Building."}

  def check({:bot, :bobby}, "building", "done", facts) do
    cond do
      !facts[:pr_and_playtest] -> {:error, "Add the PR and playtest links first."}
      !facts[:gentry_ok] -> {:error, "Wait for Gentry's check first."}
      true -> :ok
    end
  end

  def check({:founder, _}, from, "parked", _) when from in ~w(ideas refining check), do: :ok
  def check({:founder, _}, "parked", "ideas", _), do: :ok

  def check(_actor, from, to, _),
    do: {:error, "Moving a card from #{label(from)} to #{label(to)} isn't allowed for you."}

  @doc """
  The columns `actor` may try to move a card in `from` to (ignoring facts), for
  the "Move to…" buttons.

      iex> TalesForge.Board.Rules.targets({:founder, "a@x"}, "check")
      ["refining", "building", "parked"]
      iex> TalesForge.Board.Rules.targets({:founder, "a@x"}, "building")
      []
  """
  @spec targets(actor(), String.t()) :: [String.t()]
  def targets(actor, from) do
    all = %{
      pullable: true,
      refined: true,
      downvoted: false,
      pr_and_playtest: true,
      gentry_ok: true
    }

    Enum.filter(TalesForge.Board.Idea.columns(), &(check(actor, from, &1, all) == :ok))
  end

  @doc "The actor as a string for the history (`founder email` or `bot:case`)."
  @spec actor_name(actor()) :: String.t()
  def actor_name({:founder, email}), do: email
  def actor_name({:bot, bot}), do: "bot:#{bot}"

  defp need(true, _message), do: :ok
  defp need(_, message), do: {:error, message}
end
