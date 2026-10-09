defmodule TalesForge.PrFeedFixtures do
  @moduledoc "GitHub REST answers and snapshots for the live PR feed tests (mocked data only)."

  @doc "A pull request as GitHub's pulls list returns it."
  @spec pull(pos_integer(), keyword()) :: map()
  def pull(number, opts \\ []) do
    state = Keyword.get(opts, :state, :open)
    at = Keyword.get(opts, :at, "2026-10-09T10:00:00Z")

    %{
      "number" => number,
      "title" => Keyword.get(opts, :title, "PR number #{number}"),
      "user" => %{"login" => Keyword.get(opts, :author, "bobby-bot")},
      "html_url" => "https://github.com/whyse-ab/ex-tales-forge/pull/#{number}",
      "state" => if(state == :open, do: "open", else: "closed"),
      "draft" => Keyword.get(opts, :draft, false),
      "head" => %{"sha" => Keyword.get(opts, :head, "head#{number}")},
      "merge_commit_sha" => Keyword.get(opts, :merge, String.duplicate("#{number}", 7)),
      "created_at" => Keyword.get(opts, :created, at),
      "updated_at" => at,
      "merged_at" => if(state == :merged, do: at),
      "closed_at" => if(state in [:merged, :closed], do: at)
    }
  end

  @doc "A workflow-runs answer: `{head_sha, status, conclusion}` tuples, newest first."
  @spec runs([{String.t(), String.t(), String.t() | nil}]) :: map()
  def runs(list) do
    %{
      "total_count" => length(list),
      "workflow_runs" =>
        for(
          {sha, status, conclusion} <- list,
          do: %{"head_sha" => sha, "status" => status, "conclusion" => conclusion}
        )
    }
  end

  @doc "A commits answer from shas, newest first, each committed at `at`."
  @spec commits([String.t()], String.t()) :: [map()]
  def commits(shas, at \\ "2026-10-09T10:00:00Z"),
    do: Enum.map(shas, &%{"sha" => &1, "commit" => %{"committer" => %{"date" => at}}})

  @doc "Live pace numbers (`t:TalesForge.PrFeed.Pace.t/0`), with `overrides`."
  @spec pace(map()) :: map()
  def pace(overrides \\ %{}) do
    Map.merge(
      %{
        as_of: "2026-10-09",
        fetched_at: DateTime.utc_now(),
        prs_total: 1234,
        prs_merged: 1111,
        prs_open: 77,
        prs_closed_unmerged: 46,
        prs_by_day: [
          %{"date" => "2026-09-30", "created" => 5, "merged" => 4},
          %{"date" => "2026-10-08", "created" => 21, "merged" => 19},
          %{"date" => "2026-10-09", "created" => 13, "merged" => 12}
        ],
        commits: 4321,
        commits_by_day: [%{"date" => "2026-10-09", "count" => 17}],
        first_commit: "2026-07-02"
      },
      overrides
    )
  end

  @doc "An `:ok` snapshot with the given items (see `item/2`)."
  @spec snapshot([map()], keyword()) :: map()
  def snapshot(items, opts \\ []) do
    %{
      status: :ok,
      items: items,
      merged_today: Keyword.get(opts, :today, 0),
      merged_week: Keyword.get(opts, :week, 0),
      fetched_at: DateTime.utc_now(),
      pace: Keyword.get(opts, :pace)
    }
  end

  @doc "A snapshot item."
  @spec item(pos_integer(), keyword()) :: map()
  def item(number, opts \\ []) do
    %{
      number: number,
      title: Keyword.get(opts, :title, "PR number #{number}"),
      author: "bobby-bot",
      url: "https://github.com/whyse-ab/ex-tales-forge/pull/#{number}",
      state: Keyword.get(opts, :state, :open),
      draft: false,
      at: DateTime.add(DateTime.utc_now(), -300),
      ci: Keyword.get(opts, :ci),
      deployed: Keyword.get(opts, :deployed, %{playtest: :not_merged, production: :not_merged})
    }
  end
end
