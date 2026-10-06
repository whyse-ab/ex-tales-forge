defmodule TalesForge.Collab do
  @moduledoc """
  Decision queue and shared docs for founders.

  Git (`tales-forge-docs`) is the source of truth for decision/doc content.
  Comments, rank changes and recorded outcomes live in Postgres for the live UI.
  Export of decided outcomes back to Markdown is a TODO.
  """

  import Ecto.Query

  alias TalesForge.Collab.Importer
  alias TalesForge.Collab.Schemas.{Comment, Decision, Doc, Interest}
  alias TalesForge.Repo

  @topic "collab:decisions"

  def subscribe do
    Phoenix.PubSub.subscribe(TalesForge.PubSub, @topic)
  end

  def subscribe_decision(slug) when is_binary(slug) do
    Phoenix.PubSub.subscribe(TalesForge.PubSub, decision_topic(slug))
  end

  def decision_topic(slug), do: "collab:decision:#{slug}"

  def list_decisions do
    Decision
    |> order_by([d], asc: d.rank, asc: d.slug)
    |> preload([:interests])
    |> Repo.all()
  end

  def get_decision_by_slug!(slug) do
    Decision
    |> where([d], d.slug == ^slug)
    |> preload([:interests, comments: ^from(c in Comment, order_by: [asc: c.inserted_at])])
    |> Repo.one!()
  end

  def get_decision!(id), do: Repo.get!(Decision, id)

  def move_decision(slug, direction) when direction in [:up, :down] do
    delta = if direction == :up, do: -1, else: 1

    Repo.transaction(fn ->
      decisions = list_decisions()

      case Enum.find_index(decisions, &(&1.slug == slug)) do
        nil -> Repo.rollback(:not_found)
        idx -> swap_ranks(decisions, idx, idx + delta)
      end
    end)
  end

  # Already at the top/bottom: nothing to swap.
  defp swap_ranks(decisions, idx, target_idx)
       when target_idx < 0 or target_idx >= length(decisions),
       do: Enum.at(decisions, idx)

  defp swap_ranks(decisions, idx, target_idx) do
    a = Enum.at(decisions, idx)
    b = Enum.at(decisions, target_idx)

    {:ok, updated_a} =
      a
      |> Decision.changeset(%{rank: b.rank})
      |> Repo.update()

    {:ok, _} =
      b
      |> Decision.changeset(%{rank: a.rank})
      |> Repo.update()

    broadcast({:decisions_updated})
    updated_a
  end

  def record_decision(%Decision{} = decision, attrs, author_email)
      when is_binary(author_email) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("status", "decided")
      |> Map.put("decided_at", now)

    case decision |> Decision.record_outcome_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        broadcast({:decision_updated, updated.slug})
        {:ok, updated}

      error ->
        error
    end
  end

  def add_comment(%Decision{} = decision, author_email, body) do
    %Comment{}
    |> Comment.changeset(%{
      decision_id: decision.id,
      author_email: String.downcase(author_email),
      body: body
    })
    |> Repo.insert()
    |> case do
      {:ok, comment} ->
        Phoenix.PubSub.broadcast(
          TalesForge.PubSub,
          decision_topic(decision.slug),
          {:comment_added, comment}
        )

        {:ok, comment}

      error ->
        error
    end
  end

  def toggle_interested(%Decision{} = decision, email) do
    email = String.downcase(email)

    case Repo.get_by(Interest, decision_id: decision.id, email: email) do
      nil ->
        result =
          %Interest{}
          |> Interest.changeset(%{decision_id: decision.id, email: email})
          |> Repo.insert()

        broadcast({:decision_updated, decision.slug})
        result

      interest ->
        Repo.delete(interest)
        broadcast({:decision_updated, decision.slug})
        {:ok, :removed}
    end
  end

  def interested?(%Decision{} = decision, email) when is_binary(email) do
    email = String.downcase(email)
    Enum.any?(decision.interests || [], &(String.downcase(&1.email) == email))
  end

  def list_docs do
    Doc
    |> order_by([d], asc: d.path)
    |> Repo.all()
  end

  def search_docs(""), do: list_docs()

  def search_docs(query) when is_binary(query) do
    q = "%#{String.trim(query)}%"

    Doc
    |> where([d], ilike(d.title, ^q) or ilike(d.body, ^q) or ilike(d.path, ^q))
    |> order_by([d], asc: d.path)
    |> Repo.all()
  end

  def get_doc_by_path!(path), do: Repo.get_by!(Doc, path: path)

  def sync_from_path(path) when is_binary(path) do
    Importer.import_from_path(path)
  end

  def sync_from_github(token, opts \\ []) when is_binary(token) do
    Importer.import_from_github(token, opts)
  end

  defp broadcast(msg) do
    Phoenix.PubSub.broadcast(TalesForge.PubSub, @topic, msg)
  end
end
