defmodule TalesForge.Survey.ResultsTest do
  use ExUnit.Case, async: true

  import TalesForge.SurveyFixtures

  alias TalesForge.Survey.Response
  alias TalesForge.Survey.Results

  doctest Results

  defp response(login, answers, extra \\ []) do
    struct(
      %Response{
        survey_id: "test-survey",
        github_login: login,
        email: "#{login}@example.com",
        answers: answers,
        survey_version: 1,
        updated_at: ~U[2026-10-08 07:00:00.000000Z]
      },
      extra
    )
  end

  setup do
    responses = [
      response("ada", %{
        "one" => "Yes",
        "pace" => 4,
        "often" => %{"Bus" => "Daily"},
        "device" => %{"Bus" => ["Phone", "Laptop"]},
        "week" => "Evenings\nmostly",
        "paul-keywords" => ["Speeches", "Lies"],
        "paul-keywords.other" => "Monologues",
        "paul-keywords.own-word" => "hammy",
        "paul-keywords.not-mean" => "lying",
        "paul-excerpt" => "About right",
        "paul-excerpt.why" => "He got heard",
        "paul-archetypes" => %{"Knight" => "3 Love", "Witch" => "1 Never"}
      }),
      response("bo", %{
        "one" => "Maybe (old wording)",
        "pace" => 2,
        "paul-keywords" => ["Speeches"],
        "paul-excerpt" => "Too high",
        "paul-archetypes" => %{"Knight" => "2"}
      }),
      response("cy", %{}, saved_in_draft: true)
    ]

    {:ok, definition: definition(), responses: responses}
  end

  test "overview counts respondents and complete responses", %{definition: d, responses: rs} do
    overview = Results.overview(d, rs)
    assert overview.respondents == 2
    assert overview.complete == 2
    assert Enum.map(overview.users, & &1.login) == ~w(ada bo cy)
  end

  test "aggregates options, earlier wording, scales, grids, texts and follow-ups",
       %{definition: d, responses: rs} do
    by_id = Map.new(Results.aggregate(d, rs), &{&1.question.id, &1})

    one = by_id["one"]
    assert one.answered == 2

    assert %{label: "Yes", count: 1, earlier?: false, labels: "later: none · reading: one"} in one.counts

    assert %{label: "Maybe (old wording)", count: 1, earlier?: true, labels: nil} in one.counts
    assert Enum.find(by_id["pace"].counts, &(&1.label == "4")).labels == nil

    assert by_id["pace"].mean == 3.0
    assert Enum.find(by_id["pace"].counts, &(&1.label == "4")).count == 1

    [knight, witch] = by_id["paul-archetypes"].rows
    assert knight.mean == 2.5 and knight.n == 2
    assert witch.mean == 1.0

    bus = hd(by_id["device"].rows)
    assert Enum.map(bus.counts, & &1.count) == [1, 1]
    assert bus.mean == nil

    assert [%{login: "ada"}] = by_id["week"].texts
    assert [%{login: "ada", text: "Monologues"}] = by_id["paul-keywords"].other
    assert Enum.find(by_id["paul-keywords"].counts, &(&1.label == "Speeches")).count == 2

    [why] = by_id["paul-excerpt"].follow_ups
    assert why.entries == [%{login: "ada", text: "He got heard"}]
  end

  test "answer_text for each type", %{definition: d} do
    q = TalesForge.Survey.Definition.question(d, "device")

    assert Results.answer_text(q, %{"device" => %{"Bed" => ["Phone"], "Old row" => "x"}}) ==
             "Bed: Phone; Old row: x"

    assert Results.answer_text(TalesForge.Survey.Definition.question(d, "pace"), %{"pace" => 3}) ==
             "3"

    assert Results.answer_text(TalesForge.Survey.Definition.question(d, "pace"), %{}) == ""
  end

  test "CSV has one row per user and one column per question or sub-item",
       %{definition: d, responses: rs} do
    rs = [response("eve", %{"week" => ~s|=HYPERLINK("x")|}) | rs]
    [header | rows] = d |> Results.to_csv(rs) |> String.split("\r\n", trim: true)

    assert header =~ ~s("github_login","email","survey_version")
    assert header =~ ~s("Q1 one","Q1 one: labels","Q1 one: depends")
    refute header =~ "Q2 pace: labels"
    assert header =~ ~s("Q3 often: Bus","Q3 often: Bed")
    assert header =~ ~s("Q6 paul-keywords","Q6 paul-keywords: other","Q6 paul-keywords: own-word")
    assert header =~ ~s("Q7 paul-excerpt: why")
    assert length(rows) == 4

    [eve, ada | _] = rows
    assert eve =~ ~s|"'=HYPERLINK(""x"")"|
    assert ada =~ ~s("Speeches, Lies")
    assert ada =~ ~s("Yes","{""later"":null,""reading"":""one""}")
    [bo, _cy] = Enum.drop(rows, 2)
    assert bo =~ ~s|"Maybe (old wording)",""|
    assert ada =~ ~s("Evenings\nmostly")
  end

  test "Markdown summary groups by persona with votes, synonyms and ratings",
       %{definition: d, responses: rs} do
    md = Results.to_markdown(d, rs, "2026-10-08 09:00 CEST")

    assert md =~ "# Survey results: Test survey"
    assert md =~ "2 responses, 2 complete. Exported 2026-10-08 09:00 CEST"
    assert md =~ "## Paul"
    assert md =~ ~s(**Q6 Key words: "Theatrical"**, 2 answers)
    assert md =~ "- Speeches: 2"
    assert md =~ "- Other: “Monologues” (@ada)"
    assert md =~ "*Own words (synonyms)*\n\n- “hammy” (@ada)"
    assert md =~ "*Does not mean*\n\n- “lying” (@ada)"

    assert md =~
             "[turn 7](https://tp.test/admin/play/runs/#{run_id()}#turn-7), Jev 2.88, stricter scale"

    assert md =~ "About right 1 · Too high 1"
    assert md =~ "| Knight | 2.5 | 2 |"
    assert md =~ "| Row | Never | Daily |"
    assert md =~ "- “Evenings mostly” (@ada)"
    assert md =~ "- Maybe (old wording) (earlier wording): 1\n"
    assert md =~ "- Yes: 1 — `later: none · reading: one`\n"
    assert md =~ "- No: 0 — `later: move · reading: many`\n"
    assert md =~ "(mean 3.0)"
  end

  test "Markdown with no responses", %{definition: d} do
    md = Results.to_markdown(d, [], "now")
    assert md =~ "0 responses"
    assert md =~ "no answers yet"
    assert md =~ "- (none)"
  end
end
