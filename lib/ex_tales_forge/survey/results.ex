defmodule TalesForge.Survey.Results do
  @moduledoc """
  Survey results from stored responses (`TalesForge.Survey.Response`): per
  question aggregates, per-user answer text, a CSV export (one row per user,
  one column per question or sub-item) and a Markdown summary grouped by
  persona, ready to paste into the personas doc. Pure functions, no Repo.

  Answers are read against the *current* definition. An answer whose option
  text is no longer in the definition (the wording changed after it was
  given) is still counted, listed after the current options and marked
  "(earlier wording)".
  """

  alias TalesForge.Survey.Answers
  alias TalesForge.Survey.Definition
  alias TalesForge.Survey.Question
  alias TalesForge.Survey.Response
  alias TalesForge.Survey.Section

  @typedoc "Free text with who wrote it."
  @type quote_entry :: %{login: String.t(), text: String.t()}

  @typedoc "Counts for one option (or grid column); `earlier?` for old wording."
  @type count :: %{label: String.t(), count: non_neg_integer(), earlier?: boolean()}

  @typedoc "One grid row's results."
  @type row_result :: %{
          row: String.t(),
          n: non_neg_integer(),
          counts: [count()],
          mean: float() | nil
        }

  @typedoc "One question's results."
  @type question_result :: %{
          question: Question.t(),
          answered: non_neg_integer(),
          counts: [count()],
          mean: float() | nil,
          rows: [row_result()],
          texts: [quote_entry()],
          other: [quote_entry()],
          follow_ups: [%{follow_up: Question.follow_up(), entries: [quote_entry()]}]
        }

  @typedoc "One user's line in the overview."
  @type user_line :: %{
          login: String.t(),
          email: String.t() | nil,
          progress: Answers.progress(),
          updated_at: DateTime.t() | nil,
          survey_version: integer() | nil,
          saved_in_draft: boolean()
        }

  @doc "Respondent count, completed count and one line per user."
  @spec overview(Definition.t(), [Response.t()]) :: %{
          respondents: non_neg_integer(),
          complete: non_neg_integer(),
          users: [user_line()]
        }
  def overview(%Definition{} = definition, responses) do
    users =
      Enum.map(responses, fn r ->
        %{
          login: r.github_login,
          email: r.email,
          progress: Answers.progress(definition, r.answers),
          updated_at: r.updated_at,
          survey_version: r.survey_version,
          saved_in_draft: r.saved_in_draft
        }
      end)

    %{
      respondents: Enum.count(users, &(&1.progress.answered > 0)),
      complete: Enum.count(users, &(&1.progress.complete? and &1.progress.answered > 0)),
      users: users
    }
  end

  @doc "Aggregates for every question, in definition order."
  @spec aggregate(Definition.t(), [Response.t()]) :: [question_result()]
  def aggregate(%Definition{} = definition, responses) do
    definition |> Definition.questions() |> Enum.map(&aggregate_question(&1, responses))
  end

  @doc "Aggregates for one question."
  @spec aggregate_question(Question.t(), [Response.t()]) :: question_result()
  def aggregate_question(%Question{} = q, responses) do
    values =
      for r <- responses, Answers.answered?(r.answers, q), do: {r.github_login, r.answers[q.id]}

    %{
      question: q,
      answered: length(values),
      counts: option_counts(q, values),
      mean: mean(q, values),
      rows: row_results(q, values),
      texts: texts(q, values),
      other: quotes(responses, Question.sub_key(q, "other")),
      follow_ups:
        Enum.map(q.follow_ups, fn fu ->
          %{follow_up: fu, entries: quotes(responses, Question.sub_key(q, fu.id))}
        end)
    }
  end

  @doc """
  One answer as plain text (per-user view and CSV), without follow-ups.

      iex> q = %TalesForge.Survey.Question{id: "g", type: :grid, rows: ["A", "B"]}
      iex> TalesForge.Survey.Results.answer_text(q, %{"g" => %{"A" => "2", "B" => ["x", "y"]}})
      "A: 2; B: x, y"
  """
  @spec answer_text(Question.t(), map()) :: String.t()
  def answer_text(%Question{type: :grid} = q, answers) do
    cells = Map.get(answers, q.id) || %{}

    (q.rows ++ (Map.keys(cells) -- q.rows))
    |> Enum.filter(&Map.has_key?(cells, &1))
    |> Enum.map_join("; ", &"#{&1}: #{cell_text(cells[&1])}")
  end

  def answer_text(%Question{} = q, answers), do: cell_text(Map.get(answers, q.id))

  @doc "CSV header and one row per response; see the moduledoc."
  @spec to_csv(Definition.t(), [Response.t()]) :: String.t()
  def to_csv(%Definition{} = definition, responses) do
    columns = csv_columns(definition)

    header =
      ["github_login", "email", "survey_version", "last_saved_utc", "answered", "complete"] ++
        Enum.map(columns, &elem(&1, 0))

    rows =
      Enum.map(responses, fn r ->
        progress = Answers.progress(definition, r.answers)

        [
          r.github_login,
          r.email || "",
          to_string(r.survey_version || ""),
          if(r.updated_at, do: DateTime.to_iso8601(r.updated_at), else: ""),
          "#{progress.answered}/#{progress.total}",
          to_string(progress.complete?)
        ] ++ Enum.map(columns, fn {_name, fun} -> fun.(r.answers) end)
      end)

    Enum.map_join([header | rows], "", &csv_line/1)
  end

  @doc """
  A Markdown summary: the general questions, then one section per persona
  with key-word votes, own words, "does not mean" answers, excerpt ratings
  next to Jev's score, and archetype grid means. `exported_at` is a
  ready-made time label.
  """
  @spec to_markdown(Definition.t(), [Response.t()], String.t()) :: String.t()
  def to_markdown(%Definition{} = definition, responses, exported_at) do
    %{respondents: respondents, complete: complete} = overview(definition, responses)

    head = [
      "# Survey results: #{definition.title}\n\n",
      "Survey `#{definition.id}` version #{definition.version} (#{definition.status}). ",
      "#{respondents} #{plural(respondents, "response", "responses")}, #{complete} complete. ",
      "Exported #{exported_at}. Quotes are tagged with the founder's GitHub login.\n"
    ]

    body =
      definition.sections
      |> Enum.reject(&(&1.questions == []))
      |> Enum.map(&section_markdown(&1, definition, responses))

    IO.iodata_to_binary([head | body])
  end

  # -- aggregates ---------------------------------------------------------------

  defp option_counts(%Question{type: type, options: options}, values)
       when type in [:single, :excerpt, :checkboxes] do
    picked = Enum.flat_map(values, fn {_login, v} -> List.wrap(v) end)
    counts(options, picked)
  end

  defp option_counts(%Question{type: :scale, min: min, max: max}, values) do
    picked = Enum.map(values, fn {_login, v} -> to_string(v) end)
    counts(Enum.map(min..max, &Integer.to_string/1), picked)
  end

  defp option_counts(%Question{}, _values), do: []

  defp counts(labels, picked) do
    freq = Enum.frequencies(picked)
    current = Enum.map(labels, &%{label: &1, count: Map.get(freq, &1, 0), earlier?: false})

    earlier =
      freq
      |> Map.drop(labels)
      |> Enum.sort()
      |> Enum.map(fn {label, count} -> %{label: label, count: count, earlier?: true} end)

    current ++ earlier
  end

  defp mean(%Question{type: :scale}, values),
    do: average(Enum.map(values, fn {_login, v} -> v end))

  defp mean(%Question{}, _values), do: nil

  defp row_results(%Question{type: :grid} = q, values) do
    cells = Enum.map(values, fn {_login, v} -> v end)

    Enum.map(q.rows, fn row ->
      picked = cells |> Enum.map(&Map.get(&1, row)) |> Enum.reject(&is_nil/1)
      flat = Enum.flat_map(picked, &List.wrap/1)
      points = flat |> Enum.map(&Question.column_points(q, &1)) |> Enum.reject(&is_nil/1)

      %{
        row: row,
        n: length(picked),
        counts: counts(q.columns, flat),
        mean: if(q.numeric, do: average(points))
      }
    end)
  end

  defp row_results(%Question{}, _values), do: []

  defp texts(%Question{type: :text}, values),
    do: Enum.map(values, fn {login, v} -> %{login: login, text: v} end)

  defp texts(%Question{}, _values), do: []

  defp quotes(responses, key) do
    for r <- responses,
        text = r.answers[key],
        is_binary(text),
        do: %{login: r.github_login, text: text}
  end

  defp average([]), do: nil
  defp average(numbers), do: Float.round(Enum.sum(numbers) / length(numbers), 2)

  defp cell_text(nil), do: ""
  defp cell_text(list) when is_list(list), do: Enum.join(list, ", ")
  defp cell_text(value), do: to_string(value)

  # -- CSV ---------------------------------------------------------------------

  defp csv_columns(definition) do
    definition |> Definition.questions() |> Enum.flat_map(&question_columns/1)
  end

  defp question_columns(%Question{} = q) do
    label = String.trim("#{q.number} #{q.id}")
    main_columns(q, label) ++ Enum.map(Answers.sub_keys(q), &sub_column(&1, label))
  end

  defp main_columns(%Question{type: :grid, rows: rows} = q, label) do
    Enum.map(rows, fn row ->
      {"#{label}: #{row}", fn answers -> cell_text(get_in(answers, [q.id, row])) end}
    end)
  end

  defp main_columns(%Question{} = q, label), do: [{label, &answer_text(q, &1)}]

  defp sub_column(key, label) do
    sub = key |> String.split(".", parts: 2) |> List.last()
    {"#{label}: #{sub}", fn answers -> cell_text(answers[key]) end}
  end

  defp csv_line(fields), do: Enum.map_join(fields, ",", &csv_field/1) <> "\r\n"

  # Quote every field; prefix formula-looking text so a spreadsheet shows it as text.
  defp csv_field(value) do
    value = if String.match?(value, ~r/\A[=+\-@\t]/), do: "'" <> value, else: value
    ~s(") <> String.replace(value, ~s("), ~s("")) <> ~s(")
  end

  # -- Markdown ----------------------------------------------------------------

  defp section_markdown(%Section{} = section, definition, responses) do
    [
      "\n## #{section.title}\n"
      | Enum.map(section.questions, fn q ->
          question_markdown(aggregate_question(q, responses), definition)
        end)
    ]
  end

  defp question_markdown(%{question: %Question{type: :excerpt} = q} = agg, definition) do
    url = Question.turn_url(q, definition.playtest_base_url)

    [
      "\n**#{q.number} Excerpt rating** ([turn #{q.turn}](#{url}), Jev #{format_score(q.jev_score)}, ",
      "#{q.jev_scale} scale), #{agg.answered} #{plural(agg.answered, "answer", "answers")}: ",
      counts_inline(agg.counts),
      "\n",
      follow_ups_markdown(agg)
    ]
  end

  defp question_markdown(%{question: %Question{type: :grid} = q} = agg, _definition) do
    [
      "\n**#{q.number} #{strip_md(q.title)}**, #{agg.answered} #{plural(agg.answered, "answer", "answers")}\n\n",
      grid_table(q, agg.rows),
      follow_ups_markdown(agg)
    ]
  end

  defp question_markdown(%{question: %Question{type: :text} = q} = agg, _definition) do
    [
      "\n**#{q.number} #{strip_md(q.title)}**\n\n",
      quotes_list(agg.texts)
    ]
  end

  defp question_markdown(%{question: q} = agg, _definition) do
    title = if q.role == "keywords", do: "Key words: #{q.title}", else: strip_md(q.title)
    mean = if agg.mean, do: " (mean #{agg.mean})", else: ""

    [
      "\n**#{q.number} #{title}**, #{agg.answered} #{plural(agg.answered, "answer", "answers")}#{mean}\n\n",
      Enum.map(agg.counts, fn c ->
        "- #{c.label}#{if c.earlier?, do: " (earlier wording)", else: ""}: #{c.count}\n"
      end),
      Enum.map(agg.other, &"- Other: “#{one_line(&1.text)}” (@#{&1.login})\n"),
      follow_ups_markdown(agg)
    ]
  end

  defp follow_ups_markdown(agg) do
    agg.follow_ups
    |> Enum.reject(&(&1.entries == []))
    |> Enum.map(fn %{follow_up: fu, entries: entries} ->
      ["\n*#{follow_up_title(fu)}*\n\n", quotes_list(entries)]
    end)
  end

  defp follow_up_title(%{role: "synonym"}), do: "Own words (synonyms)"
  defp follow_up_title(%{role: "not_meaning"}), do: "Does not mean"
  defp follow_up_title(%{role: "why"}), do: "Why"
  defp follow_up_title(%{label: label}), do: strip_md(label)

  defp quotes_list([]), do: "- (none)\n"
  defp quotes_list(entries), do: Enum.map(entries, &"- “#{one_line(&1.text)}” (@#{&1.login})\n")

  defp grid_table(%Question{numeric: true, columns: columns}, rows) do
    sorted = Enum.sort_by(rows, &{-(&1.mean || 0), &1.row})

    [
      "| Row | Mean (1–#{length(columns)}) | Answers |\n| --- | --- | --- |\n",
      Enum.map(sorted, fn r ->
        "| #{r.row} | #{if r.mean, do: r.mean, else: "–"} | #{r.n} |\n"
      end)
    ]
  end

  defp grid_table(%Question{columns: columns}, rows) do
    [
      "| Row | #{Enum.join(columns, " | ")} |\n| --- |#{String.duplicate(" --- |", length(columns))}\n",
      Enum.map(rows, fn r ->
        cells =
          r.counts |> Enum.reject(& &1.earlier?) |> Enum.map_join(" | ", &to_string(&1.count))

        "| #{r.row} | #{cells} |\n"
      end)
    ]
  end

  defp counts_inline(counts) do
    case Enum.filter(counts, &(&1.count > 0)) do
      [] -> "no answers yet"
      nonzero -> Enum.map_join(nonzero, " · ", &"#{&1.label} #{&1.count}")
    end
  end

  defp format_score(nil), do: "–"
  defp format_score(score), do: :erlang.float_to_binary(score / 1, decimals: 2)

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()
  defp strip_md(text), do: String.replace(text, "**", "")

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many
end
