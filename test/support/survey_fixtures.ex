defmodule TalesForge.SurveyFixtures do
  @moduledoc """
  Survey test helpers: a small definition with every question type.

  The docs-dir helper serves it as the "docs copy" through a temporary
  TALES_FORGE_DOCS_PATH.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias TalesForge.Survey.Cache

  @run_id "761713eb-b3cd-4460-b4d0-34c7ba6f777c"

  @doc "The playtest run id used by the fixture's excerpt."
  def run_id, do: @run_id

  @doc "A valid definition (string keys) with every question type."
  def survey_map(overrides \\ %{}) do
    Map.merge(
      %{
        "format" => 1,
        "id" => "test-survey",
        "version" => 1,
        "status" => "open",
        "title" => "Test survey",
        "intro" => "Hello **founders**.",
        "playtest_base_url" => "https://tp.test/admin/playtest",
        "latest_findings" => %{"markdown" => "Findings land tonight.", "placeholder" => true},
        "lists" => %{
          "rating" => ["Too low", "About right", "Too high"],
          "archetypes" => ["Knight", "Witch"],
          "points" => ["1 Never", "2", "3 Love"]
        },
        "sections" => [
          %{
            "id" => "general",
            "title" => "General",
            "questions" => [
              %{
                "id" => "one",
                "number" => "Q1",
                "type" => "single",
                "title" => "One story?",
                "required" => true,
                "options" => ["Yes", "No"],
                "follow_ups" => [%{"id" => "depends", "label" => "Depends on what?"}]
              },
              %{
                "id" => "pace",
                "number" => "Q2",
                "type" => "scale",
                "title" => "Pace",
                "min" => 1,
                "max" => 5,
                "min_label" => "Quick",
                "max_label" => "Rich"
              },
              %{
                "id" => "often",
                "number" => "Q3",
                "type" => "grid",
                "title" => "How often",
                "rows" => ["Bus", "Bed"],
                "columns" => ["Never", "Daily"]
              },
              %{
                "id" => "device",
                "number" => "Q4",
                "type" => "grid",
                "title" => "Device",
                "rows" => ["Bus", "Bed"],
                "columns" => ["Phone", "Laptop"],
                "multi" => true
              },
              %{
                "id" => "week",
                "number" => "Q5",
                "type" => "text",
                "title" => "Week",
                "long" => true
              }
            ]
          },
          %{
            "id" => "paul",
            "title" => "Paul",
            "persona" => "paul",
            "markdown" => "About **Paul**.",
            "questions" => [
              %{
                "id" => "paul-keywords",
                "number" => "Q6",
                "type" => "checkboxes",
                "role" => "keywords",
                "title" => "\"Theatrical\"",
                "options" => ["Speeches", "Lies"],
                "other" => true,
                "follow_ups" => [
                  %{"id" => "own-word", "role" => "synonym", "label" => "Your own word"},
                  %{"id" => "not-mean", "role" => "not_meaning", "label" => "Does *not* mean"}
                ]
              },
              %{
                "id" => "paul-excerpt",
                "number" => "Q7",
                "type" => "excerpt",
                "title" => "Jev 2.88: right for Paul?",
                "required" => true,
                "run_id" => @run_id,
                "turn" => 7,
                "jev_score" => 2.88,
                "jev_scale" => "stricter",
                "character" => "Paul plays Corvin.",
                "context" => "At the **market**.",
                "player" => "Osric Vane, hear me.",
                "game" => "You step back into the inn."
              },
              %{
                "id" => "paul-archetypes",
                "number" => "Q8",
                "type" => "grid",
                "role" => "archetypes",
                "title" => "Paul: which archetypes?",
                "rows" => "@archetypes",
                "columns" => "@points",
                "numeric" => true
              }
            ]
          }
        ]
      },
      overrides
    )
  end

  @doc "The fixture as JSON."
  def survey_json(overrides \\ %{}), do: Jason.encode!(survey_map(overrides))

  @doc "The fixture parsed."
  def definition(overrides \\ %{}) do
    {:ok, definition} = TalesForge.Survey.Definition.from_map(survey_map(overrides))
    definition
  end

  @doc """
  Serves `json` as `docs/<id>.json` from a temporary docs checkout
  (TALES_FORGE_DOCS_PATH) and clears the definition cache. Returns the file path.
  """
  def use_docs_dir(json, id \\ "test-survey") do
    dir = Path.join(System.tmp_dir!(), "tf-survey-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "docs"))
    file = Path.join(dir, "docs/#{id}.json")
    File.write!(file, json)
    Application.put_env(:ex_tales_forge, :tales_forge_docs_path, dir)
    Cache.clear()

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.delete_env(:ex_tales_forge, :tales_forge_docs_path)
      Cache.clear()
    end)

    file
  end

  @doc "No docs checkout and no GitHub token: definitions come from priv/surveys."
  def snapshot_only do
    previous = Application.get_env(:ex_tales_forge, :github_docs_token)
    Application.delete_env(:ex_tales_forge, :tales_forge_docs_path)
    Application.put_env(:ex_tales_forge, :github_docs_token, nil)
    Cache.clear()

    on_exit(fn ->
      Application.put_env(:ex_tales_forge, :github_docs_token, previous)
      Cache.clear()
    end)

    :ok
  end
end
