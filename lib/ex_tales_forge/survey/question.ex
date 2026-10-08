defmodule TalesForge.Survey.Question do
  @moduledoc """
  One question of a survey definition (`TalesForge.Survey.Definition`).

  Types:

    * `:single` – pick one option (radio buttons).
    * `:checkboxes` – pick several options; `other: true` adds an "Other" free-text field.
    * `:scale` – a whole number from `min` to `max` (e.g. 1–5) with end labels.
    * `:grid` – one answer per row (`multi: false`, radios) or several per row
      (`multi: true`, checkboxes). `numeric: true` means column *i* is worth
      *i + 1* points, so results show a mean per row (the persona × archetype grids).
    * `:text` – free text; `long: true` for a paragraph.
    * `:excerpt` – a real playtest turn (player line and game reply) with Jev's
      score, rated on the survey's `rating` list, plus a "Why?" field.

  Every type can carry `follow_ups`: optional short free-text fields stored
  under `"<question id>.<follow-up id>"`.

  `:single` and `:checkboxes` questions can carry `option_labels`: for each
  option, a flat map of structured labels (e.g. the intent reading an option
  stands for: `%{"action" => "speak", "target" => "innkeep"}`). They are never
  shown to the person answering; the results page, the CSV and the Markdown
  export show them next to each option (`labels_text/2`, `labels_json/2`).
  """

  @typedoc "A question type."
  @type type :: :single | :checkboxes | :scale | :grid | :text | :excerpt

  @typedoc "An optional free-text field that belongs to a question."
  @type follow_up :: %{id: String.t(), label: String.t(), role: String.t() | nil}

  @typedoc "Structured labels of one option: label name to value (nil for none)."
  @type labels :: %{optional(String.t()) => String.t() | nil}

  @typedoc "A parsed question."
  @type t :: %__MODULE__{
          id: String.t(),
          number: String.t(),
          type: type(),
          title: String.t(),
          text: String.t() | nil,
          required: boolean(),
          role: String.t() | nil,
          persona: String.t() | nil,
          options: [String.t()],
          option_labels: %{optional(String.t()) => labels()},
          other: boolean(),
          rows: [String.t()],
          columns: [String.t()],
          multi: boolean(),
          numeric: boolean(),
          min: integer() | nil,
          max: integer() | nil,
          min_label: String.t() | nil,
          max_label: String.t() | nil,
          long: boolean(),
          follow_ups: [follow_up()],
          run_id: String.t() | nil,
          turn: pos_integer() | nil,
          jev_score: float() | nil,
          jev_scale: String.t() | nil,
          character: String.t() | nil,
          context: String.t() | nil,
          player: String.t() | nil,
          game: String.t() | nil,
          why_hint: String.t() | nil
        }

  defstruct [
    :id,
    :number,
    :type,
    :title,
    :text,
    :role,
    :persona,
    :min,
    :max,
    :min_label,
    :max_label,
    :run_id,
    :turn,
    :jev_score,
    :jev_scale,
    :character,
    :context,
    :player,
    :game,
    :why_hint,
    required: false,
    options: [],
    option_labels: %{},
    other: false,
    rows: [],
    columns: [],
    multi: false,
    numeric: false,
    long: false,
    follow_ups: []
  ]

  @doc """
  The answer-map key of a follow-up (or the "other" text) of a question.

      iex> TalesForge.Survey.Question.sub_key(%TalesForge.Survey.Question{id: "pace"}, "why")
      "pace.why"
  """
  @spec sub_key(t(), String.t()) :: String.t()
  def sub_key(%__MODULE__{id: id}, sub), do: id <> "." <> sub

  @doc """
  Link to the playtest turn of an excerpt question: the run page plus a
  `#turn-N` anchor. `nil` for other question types.

      iex> q = %TalesForge.Survey.Question{type: :excerpt, run_id: "abc", turn: 4}
      iex> TalesForge.Survey.Question.turn_url(q, "https://x.test/admin/playtest")
      "https://x.test/admin/playtest/abc#turn-4"
  """
  @spec turn_url(t(), String.t()) :: String.t() | nil
  def turn_url(%__MODULE__{type: :excerpt, run_id: run_id, turn: turn}, base_url),
    do: "#{String.trim_trailing(base_url, "/")}/#{run_id}#turn-#{turn}"

  def turn_url(%__MODULE__{}, _base_url), do: nil

  @doc """
  Points for a numeric grid column (its 1-based position), or nil.

      iex> q = %TalesForge.Survey.Question{type: :grid, numeric: true, columns: ["1 Never", "2", "3"]}
      iex> TalesForge.Survey.Question.column_points(q, "2")
      2
  """
  @spec column_points(t(), String.t()) :: pos_integer() | nil
  def column_points(%__MODULE__{numeric: true, columns: columns}, column) do
    case Enum.find_index(columns, &(&1 == column)) do
      nil -> nil
      index -> index + 1
    end
  end

  def column_points(%__MODULE__{}, _column), do: nil

  @doc """
  The labels of `option` as one readable line (keys in alphabetical order,
  nil shown as `none`), or nil when the option has no labels.

      iex> q = %TalesForge.Survey.Question{option_labels: %{"Buys" => %{"target" => nil, "action" => "buy"}}}
      iex> TalesForge.Survey.Question.labels_text(q, "Buys")
      "action: buy · target: none"
      iex> TalesForge.Survey.Question.labels_text(q, "Asks")
      nil
  """
  @spec labels_text(t(), String.t()) :: String.t() | nil
  def labels_text(%__MODULE__{option_labels: option_labels}, option) do
    case Map.get(option_labels, option) do
      nil ->
        nil

      labels ->
        labels
        |> Enum.sort()
        |> Enum.map_join(" · ", fn {key, value} -> "#{key}: #{value || "none"}" end)
    end
  end

  @doc """
  The labels of `option` as compact JSON (keys sorted), or nil when it has none.

      iex> q = %TalesForge.Survey.Question{option_labels: %{"Buys" => %{"target" => nil, "action" => "buy"}}}
      iex> TalesForge.Survey.Question.labels_json(q, "Buys")
      ~s({"action":"buy","target":null})
  """
  @spec labels_json(t(), String.t()) :: String.t() | nil
  def labels_json(%__MODULE__{option_labels: option_labels}, option) do
    case Map.get(option_labels, option) do
      nil -> nil
      labels -> labels |> Enum.sort() |> Jason.OrderedObject.new() |> Jason.encode!()
    end
  end

  @doc "True when at least one option carries labels."
  @spec labelled?(t()) :: boolean()
  def labelled?(%__MODULE__{option_labels: option_labels}), do: option_labels != %{}
end
