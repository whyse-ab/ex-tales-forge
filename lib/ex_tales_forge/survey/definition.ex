defmodule TalesForge.Survey.Definition do
  @moduledoc """
  A survey definition: the questions of a survey, parsed and validated from
  a JSON file (e.g. `docs/founder-survey-3.json` in tales-forge-docs).

  Wording lives in the JSON, not in code. `parse/1` checks the whole file and
  returns every problem it finds with its path (`sections[2].questions[1].options
  is missing`), so a bad docs commit shows up as a readable admin error instead
  of a crash. The format is described in the `README` next to the snapshot in
  `priv/surveys/`.

  Pinning: `id` names the survey (one response per user per id) and `version`
  is bumped by hand when a question's meaning changes. Responses record the
  version each answer was given under, and the exact file (by SHA-256) is kept
  in `survey_definitions` (`TalesForge.Survey.Snapshot`).

  Lists: `rows`, `columns` and `options` may be written as `"@name"` to reuse a
  list from the top-level `lists` object (e.g. `"@archetypes"`). Excerpt
  questions are rated on `lists.rating`.

  Option labels: `single` and `checkboxes` questions may map options to flat
  label objects (`option_labels`); see `TalesForge.Survey.Question`.

  Tabs: a survey with `"active": true` (and not `closed`) is one of the tabs on
  `/admin/survey` (`active?/1`), labelled with `tab` or else the title. An
  inactive survey stays reachable at `/admin/surveys/<id>` and its results.
  """

  alias TalesForge.Survey.Question
  alias TalesForge.Survey.Section

  @format 1
  @statuses %{"draft" => :draft, "open" => :open, "closed" => :closed}
  @types %{
    "single" => :single,
    "checkboxes" => :checkboxes,
    "scale" => :scale,
    "grid" => :grid,
    "text" => :text,
    "excerpt" => :excerpt
  }
  @slug ~r/\A[a-z0-9][a-z0-9-]*\z/
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @typedoc "Draft (answerable, marked as a draft), open, or closed (read-only)."
  @type status :: :draft | :open | :closed

  @typedoc "The 'Latest findings' box at the top of the survey."
  @type findings :: %{title: String.t(), markdown: String.t(), placeholder: boolean()}

  @typedoc "A parsed, valid survey definition."
  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          status: status(),
          active: boolean(),
          title: String.t(),
          tab: String.t() | nil,
          intro: String.t() | nil,
          estimated_minutes: pos_integer() | nil,
          playtest_base_url: String.t() | nil,
          latest_findings: findings() | nil,
          notes: [String.t()],
          how_we_use: [String.t()],
          lists: %{optional(String.t()) => [String.t()]},
          sections: [Section.t()]
        }

  defstruct [
    :id,
    :version,
    :status,
    :title,
    :tab,
    :intro,
    :estimated_minutes,
    :playtest_base_url,
    :latest_findings,
    active: false,
    notes: [],
    how_we_use: [],
    lists: %{},
    sections: []
  ]

  @doc """
  Parses and validates a JSON survey definition.

      iex> {:error, [message]} = TalesForge.Survey.Definition.parse("{")
      iex> message =~ "not valid JSON"
      true
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> from_map(map)
      {:ok, _other} -> {:error, ["the file must hold one JSON object"]}
      {:error, error} -> {:error, ["not valid JSON: " <> Exception.message(error)]}
    end
  end

  @doc """
  Validates an already decoded definition (string keys).

      iex> {:error, errors} = TalesForge.Survey.Definition.from_map(%{"format" => 1})
      iex> "id is missing" in errors
      true
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(map) when is_map(map) do
    case build(map) do
      {definition, []} -> {:ok, definition}
      {_definition, errors} -> {:error, Enum.reverse(errors)}
    end
  end

  @doc "All questions in order, across sections."
  @spec questions(t()) :: [Question.t()]
  def questions(%__MODULE__{sections: sections}), do: Enum.flat_map(sections, & &1.questions)

  @doc "The question with this id, or nil."
  @spec question(t(), String.t()) :: Question.t() | nil
  def question(%__MODULE__{} = definition, id),
    do: Enum.find(questions(definition), &(&1.id == id))

  @doc "The section with this id, or nil."
  @spec section(t(), String.t()) :: Section.t() | nil
  def section(%__MODULE__{sections: sections}, id), do: Enum.find(sections, &(&1.id == id))

  @doc """
  Is this survey one of the founder tabs? True when `active` is set and the
  survey is not closed.

      iex> TalesForge.Survey.Definition.active?(%TalesForge.Survey.Definition{active: true, status: :open})
      true
      iex> TalesForge.Survey.Definition.active?(%TalesForge.Survey.Definition{active: true, status: :closed})
      false
  """
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{active: active, status: status}), do: active and status != :closed

  @doc """
  The tab label: `tab` when set, else the title.

      iex> TalesForge.Survey.Definition.tab_title(%TalesForge.Survey.Definition{title: "Long title", tab: "Short"})
      "Short"
  """
  @spec tab_title(t()) :: String.t()
  def tab_title(%__MODULE__{tab: tab, title: title}), do: tab || title

  @doc "Can answers be saved? True for draft and open surveys, false once closed."
  @spec answerable?(t()) :: boolean()
  def answerable?(%__MODULE__{status: status}), do: status in [:draft, :open]

  @doc """
  True for a usable survey id (lowercase letters, digits and dashes).

      iex> TalesForge.Survey.Definition.valid_id?("founder-survey-3")
      true
      iex> TalesForge.Survey.Definition.valid_id?("../secrets")
      false
  """
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@slug, id)
  def valid_id?(_id), do: false

  # -- building ---------------------------------------------------------------
  #
  # A checker `%{map, path, lists, out, errs}` is piped through `take/4` and
  # friends: each step reads one key of `map`, stores the value in `out` and
  # prepends any problem to `errs`.

  defp build(map) do
    c =
      map
      |> checker("", %{}, [])
      |> check_format()
      |> take("id", :slug, required: true)
      |> take("version", :pos_integer, required: true)
      |> take_status()
      |> take("active", :boolean, default: false)
      |> take("title", :string, required: true)
      |> take("tab", :string)
      |> take("intro", :string)
      |> take("estimated_minutes", :pos_integer)
      |> take("playtest_base_url", :https_url)
      |> take("notes", {:list, :string}, default: [])
      |> take("how_we_use", {:list, :string}, default: [])
      |> take_findings()
      |> take_lists()
      |> take_sections()
      |> check_unique_question_ids()
      |> check_excerpt_base_url()

    {struct(__MODULE__, c.out), c.errs}
  end

  defp checker(map, path, lists, errs),
    do: %{map: map, path: path, lists: lists, out: %{}, errs: errs}

  defp error(c, message), do: %{c | errs: [message | c.errs]}
  defp put(c, key, value), do: %{c | out: Map.put(c.out, key, value)}

  defp check_format(c) do
    case Map.get(c.map, "format") do
      @format -> c
      nil -> error(c, "format is missing (expected #{@format})")
      other -> error(c, "format #{inspect(other)} is not supported (expected #{@format})")
    end
  end

  defp take_status(c) do
    case Map.get(c.map, "status", "draft") do
      value when is_map_key(@statuses, value) ->
        put(c, :status, Map.fetch!(@statuses, value))

      other ->
        c
        |> put(:status, :draft)
        |> error("status #{inspect(other)} must be one of draft, open, closed")
    end
  end

  defp take_findings(c) do
    case Map.get(c.map, "latest_findings") do
      nil ->
        put(c, :latest_findings, nil)

      %{} = f ->
        sub =
          f
          |> checker("latest_findings", %{}, c.errs)
          |> take("markdown", :string, required: true, default: "")
          |> take("title", :string, default: "Latest findings")
          |> take("placeholder", :boolean, default: false)

        %{c | errs: sub.errs} |> put(:latest_findings, sub.out)

      _other ->
        c |> put(:latest_findings, nil) |> error("latest_findings must be an object")
    end
  end

  defp take_lists(c) do
    case Map.get(c.map, "lists", %{}) do
      %{} = lists ->
        sub =
          lists
          |> Map.keys()
          |> Enum.reduce(
            checker(lists, "lists", %{}, c.errs),
            &take(&2, &1, {:list, :string}, required: true)
          )

        lists = for {key, value} <- sub.out, value != nil, into: %{}, do: {to_string(key), value}
        %{c | errs: sub.errs, lists: lists} |> put(:lists, lists)

      _other ->
        c |> put(:lists, %{}) |> error("lists must be an object of named string lists")
    end
  end

  defp take_sections(c) do
    case Map.get(c.map, "sections") do
      [_ | _] = sections ->
        {built, errs} =
          build_all(sections, "sections", c.errs, &build_section(&1, &2, c.lists, &3))

        %{c | errs: check_unique(Enum.map(built, & &1.id), "section id", errs)}
        |> put(:sections, built)

      _other ->
        c |> put(:sections, []) |> error("sections must be a non-empty list")
    end
  end

  # Builds every item of `list` with `fun.(item, path, errs) -> {built, errs}`.
  defp build_all(list, path, errs, fun) do
    {built, errs} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], errs}, fn {item, index}, {acc, errs_acc} ->
        {one, errs_out} = fun.(item, "#{path}[#{index}]", errs_acc)
        {[one | acc], errs_out}
      end)

    {Enum.reverse(built), errs}
  end

  defp build_section(%{} = s, path, lists, errs) do
    c =
      s
      |> checker(path, lists, errs)
      |> take("id", :slug, required: true)
      |> take("title", :string, required: true)
      |> take("persona", :string)
      |> take("markdown", :string)

    {questions, errs_out} =
      case Map.get(s, "questions", []) do
        list when is_list(list) ->
          build_all(list, "#{path}.questions", c.errs, &build_question(&1, &2, lists, &3))

        _other ->
          {[], ["#{path}.questions must be a list" | c.errs]}
      end

    persona = c.out.persona

    section =
      struct(Section, Map.put(c.out, :questions, Enum.map(questions, &%{&1 | persona: persona})))

    {section, errs_out}
  end

  defp build_section(_other, path, _lists, errs),
    do: {%Section{}, ["#{path} must be an object" | errs]}

  defp build_question(%{} = q, path, lists, errs) do
    c =
      q
      |> checker(path, lists, errs)
      |> take("id", :slug, required: true)
      |> take_type()
      |> take("number", :string, default: "")
      |> take("title", :string, required: true)
      |> take("text", :string)
      |> take("required", :boolean, default: false)
      |> take("role", :string)
      |> take_follow_ups()
      |> build_typed()

    question = struct(Question, c.out)

    {question,
     check_unique(Enum.map(question.follow_ups, & &1.id), "#{path} follow-up id", c.errs)}
  end

  defp build_question(_other, path, _lists, errs),
    do: {%Question{}, ["#{path} must be an object" | errs]}

  defp take_type(c) do
    case Map.get(c.map, "type") do
      value when is_map_key(@types, value) ->
        put(c, :type, Map.fetch!(@types, value))

      nil ->
        c |> put(:type, nil) |> error("#{c.path}.type is missing")

      other ->
        names = @types |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        c |> put(:type, nil) |> error("#{c.path}.type #{inspect(other)} is not one of #{names}")
    end
  end

  defp build_typed(%{out: %{type: :single}} = c),
    do: c |> take_list_ref("options") |> take_option_labels()

  defp build_typed(%{out: %{type: :checkboxes}} = c) do
    c =
      c
      |> take_list_ref("options")
      |> take("other", :boolean, default: false)
      |> take_option_labels()

    if c.out.other, do: reserved_follow_up(c, "other"), else: c
  end

  defp build_typed(%{out: %{type: :scale}} = c) do
    c
    |> take("min", :integer, default: 1)
    |> take("max", :integer, default: 5)
    |> take("min_label", :string)
    |> take("max_label", :string)
    |> check_scale()
  end

  defp build_typed(%{out: %{type: :grid}} = c) do
    c
    |> take_list_ref("rows")
    |> take_list_ref("columns")
    |> take("multi", :boolean, default: false)
    |> take("numeric", :boolean, default: false)
  end

  defp build_typed(%{out: %{type: :text}} = c), do: take(c, "long", :boolean, default: false)

  defp build_typed(%{out: %{type: :excerpt}} = c) do
    c
    |> take("run_id", :uuid, required: true)
    |> take("turn", :pos_integer, required: true)
    |> take("jev_score", :score, required: true)
    |> take("jev_scale", :string, default: "baseline")
    |> take("character", :string)
    |> take("context", :string)
    |> take("player", :string, required: true)
    |> take("game", :string, required: true)
    |> take("why_hint", :string)
    |> rating_options()
    |> reserved_follow_up("why")
    |> then(&put(&1, :follow_ups, [%{id: "why", label: "Why?", role: "why"} | &1.out.follow_ups]))
  end

  defp build_typed(c), do: c

  # `option_labels`: `{option text: {label: string or null}}`, every key one of
  # the question's options. Optional; never shown to the person answering.
  defp take_option_labels(c) do
    path = at(c.path, "option_labels")

    case Map.get(c.map, "option_labels", %{}) do
      %{} = labels ->
        errs =
          Enum.reduce(labels, [], fn {option, value}, acc ->
            option_label_errors(option, value, c.out.options, path) ++ acc
          end)

        %{c | errs: Enum.sort(errs, :desc) ++ c.errs} |> put(:option_labels, labels)

      _other ->
        c |> put(:option_labels, %{}) |> error("#{path} must be an object")
    end
  end

  defp option_label_errors(option, value, options, path) do
    cond do
      option not in options ->
        ["#{path} has #{inspect(option)}, which is not one of the options"]

      not is_map(value) ->
        ["#{path}[#{inspect(option)}] must be an object of labels"]

      not Enum.all?(value, fn {_key, v} -> is_nil(v) or is_binary(v) end) ->
        ["#{path}[#{inspect(option)}] values must be strings or null"]

      true ->
        []
    end
  end

  defp check_scale(%{out: %{min: min, max: max}} = c)
       when is_integer(min) and is_integer(max) and min < max and max - min <= 10,
       do: c

  defp check_scale(c), do: error(c, "#{c.path}: scale needs min < max, at most 10 apart")

  defp rating_options(c) do
    case Map.fetch(c.lists, "rating") do
      {:ok, rating} -> put(c, :options, rating)
      :error -> error(c, "#{c.path}: excerpt questions need lists.rating")
    end
  end

  defp reserved_follow_up(c, id) do
    if Enum.any?(c.out.follow_ups, &(&1.id == id)),
      do: error(c, "#{c.path}: follow-up id #{inspect(id)} is reserved"),
      else: c
  end

  defp take_follow_ups(c) do
    case Map.get(c.map, "follow_ups", []) do
      list when is_list(list) ->
        {built, errs} = build_all(list, "#{c.path}.follow_ups", c.errs, &build_follow_up/3)
        %{c | errs: errs} |> put(:follow_ups, Enum.reject(built, &is_nil/1))

      _other ->
        c |> put(:follow_ups, []) |> error("#{c.path}.follow_ups must be a list")
    end
  end

  defp build_follow_up(%{} = fu, path, errs) do
    c =
      fu
      |> checker(path, %{}, errs)
      |> take("id", :slug, required: true)
      |> take("label", :string, required: true)
      |> take("role", :string)

    {c.out, c.errs}
  end

  defp build_follow_up(_other, path, errs), do: {nil, ["#{path} must be an object" | errs]}

  defp take_list_ref(c, key) do
    atom = String.to_existing_atom(key)

    case Map.get(c.map, key) do
      "@" <> name ->
        case Map.fetch(c.lists, name) do
          {:ok, items} ->
            put(c, atom, items)

          :error ->
            c |> put(atom, []) |> error("#{at(c.path, key)} refers to unknown list @#{name}")
        end

      _other ->
        c = take(c, key, {:list, :string}, required: true, default: [])
        %{c | errs: check_unique(c.out[atom], at(c.path, key), c.errs)}
    end
  end

  defp check_unique_question_ids(c) do
    ids = c.out.sections |> Enum.flat_map(& &1.questions) |> Enum.map(& &1.id)
    %{c | errs: check_unique(ids, "question id", c.errs)}
  end

  defp check_excerpt_base_url(%{out: %{playtest_base_url: nil, sections: sections}} = c) do
    if Enum.any?(sections, fn s -> Enum.any?(s.questions, &(&1.type == :excerpt)) end),
      do: error(c, "playtest_base_url is needed for excerpt questions"),
      else: c
  end

  defp check_excerpt_base_url(c), do: c

  defp check_unique(values, what, errs) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> "duplicate #{what} #{inspect(value)}" end)
    |> Enum.reduce(errs, &[&1 | &2])
  end

  # -- typed field access -----------------------------------------------------

  defp take(c, key, kind, opts \\ []) do
    default = Keyword.get(opts, :default)
    required = Keyword.get(opts, :required, false)
    out_key = out_key(key)

    case Map.get(c.map, key) do
      nil when required -> c |> put(out_key, default) |> error("#{at(c.path, key)} is missing")
      nil -> put(c, out_key, default)
      value -> typed(c, out_key, key, kind, value, default)
    end
  end

  # List names under "lists" stay strings; everything else is a struct field.
  defp out_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp typed(c, out_key, key, kind, value, default) do
    if valid?(kind, value),
      do: put(c, out_key, normalize(kind, value)),
      else: c |> put(out_key, default) |> error("#{at(c.path, key)} must be #{describe(kind)}")
  end

  defp valid?(:string, v), do: is_binary(v) and String.trim(v) != ""
  defp valid?(:slug, v), do: valid_id?(v)
  defp valid?(:uuid, v), do: is_binary(v) and Regex.match?(@uuid, v)
  defp valid?(:https_url, v), do: is_binary(v) and String.starts_with?(v, "https://")
  defp valid?(:boolean, v), do: is_boolean(v)
  defp valid?(:integer, v), do: is_integer(v)
  defp valid?(:pos_integer, v), do: is_integer(v) and v > 0
  defp valid?(:score, v), do: is_number(v) and v >= 1 and v <= 5

  defp valid?({:list, :string}, v),
    do: is_list(v) and v != [] and Enum.all?(v, &valid?(:string, &1))

  defp normalize(:score, v), do: v / 1
  defp normalize(_kind, v), do: v

  defp describe(:string), do: "a non-empty string"
  defp describe(:slug), do: "made of a-z, 0-9 and dashes only"
  defp describe(:uuid), do: "a playtest run UUID"
  defp describe(:https_url), do: "a URL starting with https://"
  defp describe(:boolean), do: "true or false"
  defp describe(:integer), do: "a whole number"
  defp describe(:pos_integer), do: "a whole number above 0"
  defp describe(:score), do: "a number from 1 to 5"
  defp describe({:list, :string}), do: "a non-empty list of strings"

  defp at("", key), do: key
  defp at(path, key), do: "#{path}.#{key}"
end
