defmodule TalesForge.Collab.Markdown do
  @moduledoc false

  # The importer already splits YAML front matter off before storing bodies;
  # this is a safety net so a body that still carries it never renders it.
  @front_matter ~r/\A\s*---[ \t]*\r?\n.*?\r?\n---[ \t]*(\r?\n|\z)/s

  def to_html(nil), do: {:safe, ""}
  def to_html(""), do: {:safe, ""}

  def to_html(markdown) when is_binary(markdown) do
    markdown = strip_front_matter(markdown)

    case Earmark.as_html(markdown, escape: false, compact_output: true) do
      {:ok, html, _warnings} ->
        {:safe, html}

      {:error, html, _warnings} ->
        {:safe, html}
    end
  end

  def strip_front_matter(markdown) when is_binary(markdown) do
    String.replace(markdown, @front_matter, "", global: false)
  end
end
