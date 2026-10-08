defmodule TalesForge.Survey.AnswersTest do
  use ExUnit.Case, async: true

  import TalesForge.SurveyFixtures

  alias TalesForge.Survey.Answers
  alias TalesForge.Survey.Definition

  doctest Answers

  setup do
    definition = definition()

    {:ok,
     definition: definition,
     general: Definition.section(definition, "general"),
     paul: Definition.section(definition, "paul")}
  end

  test "reads every question type from form params", %{general: general, paul: paul} do
    params = %{
      "one" => "Yes",
      "one.depends" => "  weather  ",
      "pace" => "4",
      "often" => %{"0" => "Daily", "1" => "Never", "9" => "Daily"},
      "device" => %{"0" => ["", "Phone", "Laptop"], "1" => [""]},
      "week" => "Evenings."
    }

    assert Answers.from_params(general, params) == %{
             "one" => "Yes",
             "one.depends" => "weather",
             "pace" => 4,
             "often" => %{"Bus" => "Daily", "Bed" => "Never"},
             "device" => %{"Bus" => ["Phone", "Laptop"]},
             "week" => "Evenings."
           }

    paul_params = %{
      "paul-keywords" => ["", "Lies", "Hacking"],
      "paul-keywords.other" => "Monologues",
      "paul-keywords.own-word" => "dramatic",
      "paul-excerpt" => "About right",
      "paul-excerpt.why" => "fair",
      "paul-archetypes" => %{"0" => "3 Love", "1" => "1 Never"}
    }

    answers = Answers.from_params(paul, paul_params)
    assert answers["paul-keywords"] == ["Lies"]
    assert answers["paul-keywords.other"] == "Monologues"
    assert answers["paul-keywords.not-mean"] == nil
    assert answers["paul-excerpt"] == "About right"
    assert answers["paul-archetypes"] == %{"Knight" => "3 Love", "Witch" => "1 Never"}
  end

  test "invalid or empty values become nil (cleared)", %{general: general, paul: paul} do
    params = %{
      "one" => "Maybe",
      "pace" => "9",
      "often" => %{"0" => "Sometimes"},
      "device" => "x",
      "week" => "   "
    }

    assert general |> Answers.from_params(params) |> Map.values() |> Enum.all?(&is_nil/1)

    assert Answers.from_params(paul, %{"paul-keywords" => [""], "paul-excerpt" => 3})[
             "paul-keywords"
           ] == nil

    assert Answers.from_params(general, %{"pace" => "x"})["pace"] == nil
  end

  test "caps free text" do
    section = Definition.section(definition(), "general")

    assert String.length(
             Answers.from_params(section, %{"week" => String.duplicate("a", 5000)})["week"]
           ) == 4000
  end

  test "changed questions and progress", %{definition: definition} do
    stored = %{"one" => "Yes", "pace" => 3}

    assert Answers.changed_questions(stored, %{"one" => "Yes", "pace" => 4, "one.depends" => "x"})
           |> Enum.sort() == ["one", "pace"]

    progress = Answers.progress(definition, %{"one" => "Yes", "often" => %{}})

    assert progress == %{
             answered: 1,
             total: 8,
             required_answered: 1,
             required_total: 2,
             complete?: false
           }

    assert Answers.progress(definition, %{"one" => "No", "paul-excerpt" => "Too low"}).complete?
    refute Answers.answered?(%{"week" => ""}, Definition.question(definition, "week"))

    refute Answers.answered?(
             %{"paul-keywords" => []},
             Definition.question(definition, "paul-keywords")
           )
  end

  test "keys include follow-ups, other and why", %{definition: definition} do
    assert Answers.keys(Definition.question(definition, "paul-keywords")) ==
             [
               "paul-keywords",
               "paul-keywords.other",
               "paul-keywords.own-word",
               "paul-keywords.not-mean"
             ]

    assert Answers.keys(Definition.question(definition, "paul-excerpt")) == [
             "paul-excerpt",
             "paul-excerpt.why"
           ]
  end
end
