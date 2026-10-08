defmodule TalesForgeWeb.LinkCrawlTest do
  @moduledoc """
  Link check for the signed-in app: seeds a session, a playtest run, docs and a
  decision, then crawls from the player home and the admin dashboard, following
  every internal `href` and `src`, and asserts each one answers (no 404, no
  500, no redirect to the login page). Two pages per route are enough to cover
  every template; it runs in about a second and needs no network.

  Not followed: external links (checked by hand, GitHub repos may be private),
  `data-method` links (sign out is a DELETE), the LiveDashboard's own pages
  under `/admin/oban/` and the built `/assets/*` (not built in CI: their
  folder must be one of `TalesForgeWeb.static_paths/0` instead).
  """
  use TalesForgeWeb.ConnCase, async: false

  alias TalesForge.Collab.Importer
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{PlaytestRun, PlaytestScore, Turn}

  @per_route 2

  setup %{conn: conn} do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      Application.delete_env(:ex_tales_forge, :code_docs_dir)
      Application.delete_env(:ex_tales_forge, :tales_forge_docs_path)
    end)

    dir = Path.join(System.tmp_dir!(), "crawl_code_docs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.html"), "<html><body>Code docs</body></html>")
    Application.put_env(:ex_tales_forge, :code_docs_dir, dir)

    # A local tales-forge-docs checkout for the doc images (no GitHub in tests).
    File.mkdir_p!(Path.join(dir, "repo/docs/images"))
    File.write!(Path.join(dir, "repo/docs/images/score.png"), <<137, 80, 78, 71>>)
    Application.put_env(:ex_tales_forge, :tales_forge_docs_path, Path.join(dir, "repo"))
    on_exit(fn -> File.rm_rf!(dir) end)

    seed()
    {:ok, conn: log_in_admin(conn)}
  end

  test "every internal link on the signed-in pages resolves", %{conn: conn} do
    {visited, broken} = crawl(conn, ["/", "/admin"], %{}, [])

    assert broken == [], "broken links:\n" <> Enum.map_join(Enum.reverse(broken), "\n", & &1)

    # The crawl really reached the pages that carry the most links.
    for page <- ~w(/admin/docs /admin/decisions /admin/playtest /admin/sessions /admin/costs) do
      assert Map.has_key?(visited, page), "crawl never reached #{page}"
    end

    assert Enum.any?(Map.keys(visited), &String.starts_with?(&1, "/admin/playtest/"))
    assert Enum.any?(Map.keys(visited), &String.starts_with?(&1, "/admin/docs/"))
    assert Enum.any?(Map.keys(visited), &String.starts_with?(&1, "/admin/decisions/"))
  end

  defp seed do
    {:ok, session} = GameSessions.create_session(%{name: "Crawl", adventure_id: "tin_valley"})

    run =
      Repo.insert!(%PlaytestRun{
        game_session_id: session.id,
        persona: "paul",
        module: "tin_valley",
        build: "0.1.0",
        git_sha: "2a6589edcfcb2066731d951a7cd6c7fe45bdebd4",
        flags: %{"variant" => "default"},
        turn_limit: 2,
        turns_played: 1,
        status: "finished",
        stop_reason: "turn_limit",
        started_at: ~U[2026-10-07 17:38:00Z],
        finished_at: ~U[2026-10-07 17:40:00Z]
      })

    Repo.insert!(%Turn{
      game_session_id: session.id,
      turn_number: 1,
      player_action: "I ask Brenna about the orcs.",
      narrative: "Brenna lowers her voice."
    })

    Repo.insert!(%PlaytestScore{
      playtest_run_id: run.id,
      kind: "session_affect",
      source: "jev",
      model: "jev",
      rubric_version: "paul-v2",
      overall: 4.1,
      scores: %{}
    })

    {:ok, _} =
      Importer.upsert_doc_markdown(
        """
        # Founder survey

        Replaces [survey 2](founder-survey-2.md); scores per [persona](personas.md#paul).
        See the [decision](../decisions/d-008-tin-valley-starter.md), the
        [script](scripts/jev-rescore/rescore.exs) and the [playtest page](/admin/playtest).

        ![Score by turn](images/score.png)
        """,
        "docs/founder-survey-3.md"
      )

    {:ok, _} = Importer.upsert_doc_markdown("# Survey 2\n\nOld.", "docs/founder-survey-2.md")

    {:ok, _} =
      Importer.upsert_doc_markdown("# Personas\n\n## Paul\n\nTheatre.", "docs/personas.md")

    {:ok, _} =
      Importer.upsert_decision_markdown(
        """
        ---
        id: d-008-tin-valley-starter
        title: Tin Valley starter
        rank: 1
        ---
        Background in [the decision log](../docs/founder-survey-3.md#founder-survey).
        """,
        "decisions/d-008-tin-valley-starter.md"
      )
  end

  defp crawl(_conn, [], visited, broken), do: {visited, broken}

  defp crawl(conn, [path | queue], visited, broken) do
    if Map.has_key?(visited, path) or route_full?(visited, path) do
      crawl(conn, queue, visited, broken)
    else
      {status, location, html} = fetch(conn, path)
      visited = Map.put(visited, path, status)

      broken =
        case check(status, location) do
          :ok -> broken
          {:error, why} -> ["#{path}: #{why}" | broken]
        end

      found = if html, do: internal_links(path, html), else: []
      crawl(conn, queue ++ found, visited, broken)
    end
  end

  defp fetch(conn, path) do
    conn = conn |> recycle() |> log_in_admin() |> get(path)
    location = conn |> get_resp_header("location") |> List.first()
    html? = conn |> get_resp_header("content-type") |> Enum.any?(&(&1 =~ "text/html"))
    {conn.status, location, if(conn.status == 200 and html?, do: conn.resp_body)}
  rescue
    # ConnTest re-raises what the app would render as a 404/500 page.
    error -> {"raised #{inspect(error.__struct__)}", nil, nil}
  end

  defp check(200, _location), do: :ok

  defp check(status, location) when status in [301, 302] do
    if location && String.starts_with?(location, "/admin/login"),
      do: {:error, "redirects to the login page"},
      else: :ok
  end

  defp check(status, _location), do: {:error, "#{status}"}

  defp internal_links(page, html) do
    doc = LazyHTML.from_document(html)

    links =
      (doc |> LazyHTML.query("a[href]:not([data-method])") |> LazyHTML.attribute("href")) ++
        (doc |> LazyHTML.query("[src]") |> LazyHTML.attribute("src")) ++
        (doc |> LazyHTML.query("link[href]") |> LazyHTML.attribute("href"))

    for link <- Enum.uniq(links),
        uri = URI.merge(URI.parse("http://app.test" <> page), link),
        uri.host == "app.test",
        path = uri.path,
        followed?(path),
        uniq: true,
        do: path
  end

  defp followed?("/assets/" <> _ = path) do
    [_, top | _] = String.split(path, "/")
    assert top in TalesForgeWeb.static_paths(), "#{path} is not under a static path"
    false
  end

  defp followed?("/admin/oban/" <> _), do: false
  defp followed?(_path), do: true

  # Pages with ids (/admin/sessions/<id>, /play/<id>...) are one template each.
  defp route_full?(visited, path) do
    pattern = route_pattern(path)

    pattern != path and
      Enum.count(Map.keys(visited), &(route_pattern(&1) == pattern)) >= @per_route
  end

  defp route_pattern(path),
    do:
      Regex.replace(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, path, ":id")
end
