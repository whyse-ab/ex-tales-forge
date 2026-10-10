defmodule TalesForge.Board.Api do
  @moduledoc """
  The bots' side of the idea board, behind `/internal/board/*`
  (`TalesForgeWeb.BoardApiController` hands each authorised call here; see the
  `TalesForge.BoardApi` contract). JSON in, JSON out:

  - `GET /ideas` (`?column=ideas`): the cards, ranked Ideas first.
  - `GET /ideas/:id`: one card with refinement, votes, comments, links, history.
  - `POST /ideas/:id/refinement` (Case): `details`, `open_questions`,
    `rough_cost` (S/M/L), `verdict`.
  - `POST /ideas/:id/move`: `to` (a column), optional `note`. Gates as in
    `TalesForge.Board.Transitions`.
  - `POST /ideas/:id/links`: `kind` (pr, playtest, doc, other), `url`, `label`.
  - `POST /ideas/:id/comments`: `body`. Gentry passes a card with
    `"verdict": "pass"` (the comment then starts "Gentry check: pass").

  `POST /internal/board/prs` (Bobby only, 403 for the others): a normal-lane
  PR that needs a founder's merge OK. JSON `number`, `url`, `head_sha`,
  `player_note` (one line: what changes for players) and `idea_id` (an existing
  card) or `title` (a new card). The card goes to Founder check; the founder's
  Approve / Request changes wakes Bobby with `pr.approved` /
  `pr.changes_requested`. Fast-lane PRs need no OK: don't post them.

  Errors: 404 unknown card, 422 with `{"error": "..."}` for a refused change.
  """

  @behaviour TalesForge.BoardApi

  alias TalesForge.Board
  alias TalesForge.Board.{Idea, Transitions}

  @impl TalesForge.BoardApi
  @spec handle(TalesForge.BoardApi.action(), TalesForge.BoardApi.bot(), map()) ::
          TalesForge.BoardApi.answer()
  def handle(:index, _bot, params) do
    board = Board.board()
    columns = if params["column"] in Idea.columns(), do: [params["column"]], else: Idea.columns()
    {200, %{"ideas" => Enum.flat_map(columns, fn c -> Enum.map(board[c], &card/1) end)}}
  end

  def handle(:pr, :bobby, params), do: params |> Board.link_pr() |> answer()

  def handle(:pr, _bot, _params),
    do: {403, %{"error" => "Only Bobby puts PRs up for a founder's OK."}}

  def handle(action, bot, %{"id" => id} = params) do
    case Board.get_idea(id) do
      nil -> {404, %{"error" => "No such card."}}
      idea -> act(action, bot, idea, params)
    end
  end

  def handle(_action, _bot, _params), do: {404, %{"error" => "No such card."}}

  defp act(:show, _bot, idea, _params), do: {200, card(idea)}

  defp act(:refine, :case, idea, params),
    do:
      params
      |> Map.take(~w(details open_questions rough_cost verdict))
      |> then(&Board.refine(idea, &1))
      |> answer()

  defp act(:refine, _bot, _idea, _params), do: {422, %{"error" => "Only Case refines cards."}}

  defp act(:move, bot, idea, params),
    do: idea |> Board.move({:bot, bot}, to_string(params["to"]), params["note"]) |> answer()

  defp act(:link, bot, idea, params),
    do: idea |> Board.add_link("bot:#{bot}", Map.take(params, ~w(kind url label))) |> answer()

  defp act(:comment, bot, idea, params) do
    body =
      if bot == :gentry and params["verdict"] == "pass",
        do: Board.gentry_pass() <> ". " <> to_string(params["body"] || ""),
        else: params["body"]

    idea |> Board.add_comment("bot:#{bot}", to_string(body || "")) |> answer()
  end

  defp answer({:ok, idea}), do: {200, card(idea)}
  defp answer({:error, %Ecto.Changeset{} = cs}), do: {422, %{"error" => errors(cs)}}
  defp answer({:error, message}), do: {422, %{"error" => message}}

  defp errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  @doc "A card as JSON (everything loaded)."
  @spec card(Idea.t()) :: map()
  def card(%Idea{} = idea) do
    %{
      "id" => idea.id,
      "title" => idea.title,
      "body" => idea.body,
      "column" => idea.column,
      "column_label" => Transitions.label(idea.column),
      "author" => idea.author,
      "score" => Float.round(idea.score * 1.0, 3),
      "net_votes" => Board.net_votes(idea),
      "downvoted" => Board.downvoted?(idea),
      "refinement" => idea.refinement,
      "refined" => Board.refined?(idea),
      "pr" =>
        idea.pr_number &&
          %{
            "number" => idea.pr_number,
            "url" => idea.pr_url,
            "head_sha" => idea.pr_head_sha,
            "player_note" => idea.player_note
          },
      "approvals" =>
        Enum.map(
          idea.approvals,
          &%{
            "decision" => &1.decision,
            "founder" => &1.founder,
            "pr_number" => &1.pr_number,
            "head_sha" => &1.head_sha,
            "comment" => &1.comment,
            "at" => &1.inserted_at
          }
        ),
      "decision" =>
        idea.decision_sha && %{"slug" => idea.decision_slug, "sha" => idea.decision_sha},
      "url" => TalesForge.Board.url(idea),
      "votes" => Enum.map(idea.votes, &%{"founder" => &1.founder, "value" => &1.value}),
      "comments" =>
        Enum.map(
          idea.comments,
          &%{"author" => &1.author, "body" => &1.body, "at" => &1.inserted_at}
        ),
      "links" =>
        Enum.map(idea.links, &%{"kind" => &1.kind, "url" => &1.url, "label" => &1.label}),
      "history" =>
        Enum.map(
          idea.transitions,
          &%{
            "from" => &1.from,
            "to" => &1.to,
            "actor" => &1.actor,
            "note" => &1.note,
            "at" => &1.inserted_at
          }
        )
    }
  end
end
