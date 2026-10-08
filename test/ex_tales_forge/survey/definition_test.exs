defmodule TalesForge.Survey.DefinitionTest do
  use ExUnit.Case, async: true

  import TalesForge.SurveyFixtures

  alias TalesForge.Survey.Definition
  alias TalesForge.Survey.Question

  doctest Definition
  doctest Question

  test "the shipped founder survey snapshot is valid" do
    path = Path.join([File.cwd!(), "priv/surveys/founder-survey-3.json"])
    assert {:ok, definition} = Definition.parse(File.read!(path))

    assert definition.id == "founder-survey-3"
    assert Definition.active?(definition)
    refute definition.latest_findings.placeholder
    assert definition.status == :open
    assert length(Definition.questions(definition)) == 27

    excerpts = definition |> Definition.questions() |> Enum.filter(&(&1.type == :excerpt))
    assert length(excerpts) == 10
    assert Enum.all?(excerpts, &(&1.persona in ~w(paul lotta lars hawk ronny)))

    grids = definition |> Definition.questions() |> Enum.filter(&(&1.role == "archetypes"))
    assert length(grids) == 5
    assert Enum.all?(grids, &(length(&1.rows) == 10 and &1.numeric))
  end

  test "the shipped intent survey snapshot is valid and labels every option" do
    path = Path.join([File.cwd!(), "priv/surveys/founder-survey-4-intent.json"])
    assert {:ok, definition} = Definition.parse(File.read!(path))
    assert definition.id == "founder-survey-4-intent"
    assert Definition.active?(definition)
    assert Definition.tab_title(definition) == "What did the player mean?"

    singles = definition |> Definition.questions() |> Enum.filter(&(&1.type == :single))
    assert length(singles) == 12

    for q <- singles do
      assert Enum.sort(Map.keys(q.option_labels)) == Enum.sort(q.options)
      assert "Unclear, the game should ask the player" in q.options
      assert Enum.map(q.follow_ups, & &1.id) == ["something-else", "comment"]
    end
  end

  test "option labels: parsed for single and checkboxes, checked against the options" do
    one = Definition.question(definition(), "one")
    assert one.option_labels["No"] == %{"reading" => "many", "later" => "move"}
    assert Question.labelled?(one)
    refute Question.labelled?(Definition.question(definition(), "paul-keywords"))

    bad =
      survey_map(%{
        "sections" => [
          %{
            "id" => "s",
            "title" => "S",
            "questions" => [
              %{
                "id" => "a",
                "type" => "single",
                "title" => "A",
                "options" => ["x", "y"],
                "option_labels" => %{"z" => %{}, "x" => "speak", "y" => %{"n" => 1}}
              },
              %{
                "id" => "b",
                "type" => "checkboxes",
                "title" => "B",
                "options" => ["x"],
                "option_labels" => ["x"]
              }
            ]
          }
        ]
      })

    assert {:error, errors} = Definition.from_map(bad)
    joined = Enum.join(errors, "\n")

    for expected <- [
          ~s(sections[0].questions[0].option_labels has "z", which is not one of the options),
          ~s(sections[0].questions[0].option_labels["x"] must be an object of labels),
          ~s(sections[0].questions[0].option_labels["y"] values must be strings or null),
          "sections[0].questions[1].option_labels must be an object"
        ] do
      assert joined =~ expected
    end
  end

  test "active and tab: off by default, and a closed survey is never a tab" do
    refute Definition.active?(definition())
    assert Definition.tab_title(definition()) == "Test survey"
    assert Definition.active?(definition(%{"active" => true, "status" => "draft"}))
    refute Definition.active?(definition(%{"active" => true, "status" => "closed"}))
    assert Definition.tab_title(definition(%{"tab" => "Short"})) == "Short"

    assert {:error, errors} = Definition.from_map(survey_map(%{"active" => "yes", "tab" => ""}))
    assert "active must be true or false" in errors
    assert "tab must be a non-empty string" in errors
  end

  test "the fixture parses with every type, lists resolved and personas set" do
    definition = definition()

    assert definition.status == :open
    assert Definition.answerable?(definition)
    assert Definition.section(definition, "paul").persona == "paul"

    excerpt = Definition.question(definition, "paul-excerpt")
    assert excerpt.options == ["Too low", "About right", "Too high"]
    assert [%{id: "why"}] = excerpt.follow_ups
    assert excerpt.persona == "paul"
    assert Question.turn_url(excerpt, definition.playtest_base_url) =~ "/#{run_id()}#turn-7"

    grid = Definition.question(definition, "paul-archetypes")
    assert grid.rows == ["Knight", "Witch"]
    assert Question.column_points(grid, "3 Love") == 3
    assert Question.column_points(grid, "nope") == nil
    assert Question.column_points(Definition.question(definition, "often"), "Daily") == nil
    assert Question.turn_url(grid, "https://x") == nil
  end

  test "closed surveys are not answerable" do
    refute Definition.answerable?(definition(%{"status" => "closed"}))
  end

  test "collects every problem with its path instead of raising" do
    bad =
      survey_map(%{
        "format" => 2,
        "id" => "Bad Id",
        "status" => "maybe",
        "playtest_base_url" => "http://plain",
        "latest_findings" => %{"placeholder" => "yes"},
        "lists" => %{"rating" => []},
        "sections" => [
          %{
            "id" => "s",
            "title" => "S",
            "questions" => [
              %{"id" => "a", "type" => "single", "title" => "A"},
              %{"id" => "a", "type" => "scale", "title" => "B", "min" => 5, "max" => 1},
              %{
                "id" => "c",
                "type" => "checkboxes",
                "title" => "C",
                "options" => ["x", "x"],
                "other" => true,
                "follow_ups" => [%{"id" => "other", "label" => "clash"}, "nope"]
              },
              %{"id" => "d", "type" => "excerpt", "title" => "D", "turn" => 0},
              %{
                "id" => "e",
                "type" => "grid",
                "title" => "E",
                "rows" => "@missing",
                "columns" => 3
              },
              "not a question",
              %{"title" => "no id or type"}
            ]
          },
          "not a section",
          %{"id" => "s", "title" => "dup", "questions" => "no"}
        ]
      })

    assert {:error, errors} = Definition.from_map(bad)
    joined = Enum.join(errors, "\n")

    for expected <- [
          "format 2 is not supported",
          "id must be made of a-z",
          "status \"maybe\"",
          "playtest_base_url must be a URL starting with https://",
          "latest_findings.markdown is missing",
          "latest_findings.placeholder must be true or false",
          "lists.rating must be a non-empty list of strings",
          "sections[0].questions[0].options is missing",
          "scale needs min < max",
          "duplicate sections[0].questions[2].options \"x\"",
          "follow-up id \"other\" is reserved",
          "sections[0].questions[2].follow_ups[1] must be an object",
          "sections[0].questions[3].run_id is missing",
          "sections[0].questions[3].turn must be a whole number above 0",
          "excerpt questions need lists.rating",
          "refers to unknown list @missing",
          "sections[0].questions[4].columns must be a non-empty list",
          "sections[0].questions[5] must be an object",
          "sections[0].questions[6].type is missing",
          "sections[1] must be an object",
          "sections[2].questions must be a list",
          "duplicate question id \"a\"",
          "duplicate section id \"s\""
        ] do
      assert joined =~ expected
    end
  end

  test "rejects non-objects and missing sections" do
    assert {:error, ["the file must hold one JSON object"]} = Definition.parse("[1]")
    assert {:error, errors} = Definition.parse(~s({"format": 1, "lists": 3, "sections": []}))
    assert "sections must be a non-empty list" in errors
    assert "lists must be an object of named string lists" in errors
    assert "format is missing (expected 1)" in elem(Definition.parse("{}"), 1)

    assert {:error, errors} =
             Definition.from_map(
               survey_map(%{"latest_findings" => "x", "playtest_base_url" => nil})
             )

    assert "latest_findings must be an object" in errors
    assert "playtest_base_url is needed for excerpt questions" in errors

    bad_types =
      survey_map(%{
        "sections" => [
          %{
            "id" => "s",
            "title" => "S",
            "questions" => [
              %{"id" => "t", "type" => "bogus", "title" => "T"},
              %{"id" => "f", "type" => "text", "title" => "F", "follow_ups" => 1}
            ]
          }
        ]
      })

    assert {:error, errors} = Definition.from_map(bad_types)
    assert Enum.any?(errors, &(&1 =~ ~s(type "bogus" is not one of)))
    assert "sections[0].questions[1].follow_ups must be a list" in errors
  end
end
