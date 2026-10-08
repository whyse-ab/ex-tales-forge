defmodule TalesForge.Survey.Answers do
  @moduledoc """
  Turns a section's form params into stored answers, and reads answers back.
  Pure functions, no Repo.

  Form params use the same keys as the stored answers (see
  `TalesForge.Survey.Response`): `params[question_id]` for the main answer
  and `params["question_id.sub"]` for follow-ups, "other" text and "why".
  Grid rows are posted by row index and stored by row label. Values that are
  not one of the question's options are dropped, free text is trimmed and
  capped at #{4000} characters.
  """

  alias TalesForge.Survey.Definition
  alias TalesForge.Survey.Question
  alias TalesForge.Survey.Section

  @max_text 4000

  @typedoc "A stored answer value."
  @type value :: String.t() | [String.t()] | integer() | %{optional(String.t()) => term()}

  @typedoc "Answers by key; nil means cleared."
  @type answers :: %{optional(String.t()) => value() | nil}

  @typedoc "How far a user got."
  @type progress :: %{
          answered: non_neg_integer(),
          total: non_neg_integer(),
          required_answered: non_neg_integer(),
          required_total: non_neg_integer(),
          complete?: boolean()
        }

  @doc """
  Every answer of `section` read from the posted `params`; a key whose field
  is empty maps to nil (so saving clears it).
  """
  @spec from_params(Section.t(), map()) :: answers()
  def from_params(%Section{questions: questions}, params) when is_map(params) do
    Enum.reduce(questions, %{}, fn question, acc ->
      acc
      |> Map.put(question.id, main_value(question, Map.get(params, question.id)))
      |> put_subs(question, params)
    end)
  end

  @doc """
  Merges a section's answers into the stored ones, dropping cleared keys.

      iex> TalesForge.Survey.Answers.merge(%{"a" => "x", "b" => "y"}, %{"a" => nil, "c" => 3})
      %{"b" => "y", "c" => 3}
  """
  @spec merge(answers(), answers()) :: answers()
  def merge(stored, section_answers) do
    Enum.reduce(section_answers, stored, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  @doc "Question ids among `section_answers` whose main answer changed from `stored`."
  @spec changed_questions(answers(), answers()) :: [String.t()]
  def changed_questions(stored, section_answers) do
    section_answers
    |> Enum.filter(fn {key, value} -> Map.get(stored, key) != value end)
    |> Enum.map(fn {key, _value} -> key |> String.split(".", parts: 2) |> hd() end)
    |> Enum.uniq()
  end

  @doc """
  Has the question's main answer been given? (Grids: at least one row.)

      iex> q = %TalesForge.Survey.Question{id: "pace", type: :scale}
      iex> TalesForge.Survey.Answers.answered?(%{"pace" => 3}, q)
      true
  """
  @spec answered?(answers(), Question.t()) :: boolean()
  def answered?(answers, %Question{id: id}) do
    case Map.get(answers, id) do
      nil -> false
      "" -> false
      [] -> false
      map when is_map(map) -> map_size(map) > 0
      _value -> true
    end
  end

  @doc "Counts answered and required questions."
  @spec progress(Definition.t(), answers()) :: progress()
  def progress(%Definition{} = definition, answers) do
    questions = Definition.questions(definition)
    required = Enum.filter(questions, & &1.required)
    answered = Enum.count(questions, &answered?(answers, &1))
    required_answered = Enum.count(required, &answered?(answers, &1))

    %{
      answered: answered,
      total: length(questions),
      required_answered: required_answered,
      required_total: length(required),
      complete?: required_answered == length(required)
    }
  end

  @doc "Every answer key a question can use: its id plus its sub keys."
  @spec keys(Question.t()) :: [String.t()]
  def keys(%Question{} = question), do: [question.id | sub_keys(question)]

  @doc "The sub keys (follow-ups, and \"other\" for checkboxes with `other: true`)."
  @spec sub_keys(Question.t()) :: [String.t()]
  def sub_keys(%Question{} = question) do
    other = if question.type == :checkboxes and question.other, do: ["other"], else: []
    Enum.map(other ++ Enum.map(question.follow_ups, & &1.id), &Question.sub_key(question, &1))
  end

  defp put_subs(acc, question, params) do
    Enum.reduce(sub_keys(question), acc, fn key, acc ->
      Map.put(acc, key, text(Map.get(params, key)))
    end)
  end

  defp main_value(%Question{type: type, options: options}, value)
       when type in [:single, :excerpt] do
    if is_binary(value) and value in options, do: value
  end

  defp main_value(%Question{type: :checkboxes, options: options}, values) when is_list(values) do
    case Enum.filter(options, &(&1 in values)) do
      [] -> nil
      picked -> picked
    end
  end

  defp main_value(%Question{type: :scale, min: min, max: max}, value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= min and n <= max -> n
      _other -> nil
    end
  end

  defp main_value(%Question{type: :grid} = question, rows) when is_map(rows) do
    question.rows
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {row, index}, acc ->
      case grid_cell(question, Map.get(rows, Integer.to_string(index))) do
        nil -> acc
        cell -> Map.put(acc, row, cell)
      end
    end)
    |> case do
      empty when map_size(empty) == 0 -> nil
      cells -> cells
    end
  end

  defp main_value(%Question{type: :text}, value), do: text(value)
  defp main_value(%Question{}, _value), do: nil

  defp grid_cell(%Question{multi: false, columns: columns}, value) when is_binary(value) do
    if value in columns, do: value
  end

  defp grid_cell(%Question{multi: true, columns: columns}, values) when is_list(values) do
    case Enum.filter(columns, &(&1 in values)) do
      [] -> nil
      picked -> picked
    end
  end

  defp grid_cell(%Question{}, _value), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @max_text)
    end
  end

  defp text(_value), do: nil
end
