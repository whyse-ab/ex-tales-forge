defmodule TalesForge.Survey.Section do
  @moduledoc """
  A section of a survey definition: a title, optional read-only markdown and
  its questions. A section with a `persona` (e.g. `"paul"`) groups that
  persona's answers in the results and the Markdown export.
  """

  alias TalesForge.Survey.Question

  @typedoc "A parsed section."
  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          persona: String.t() | nil,
          markdown: String.t() | nil,
          questions: [Question.t()]
        }

  defstruct [:id, :title, :persona, :markdown, questions: []]
end
