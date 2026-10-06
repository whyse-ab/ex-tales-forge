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
        {:safe, wrap_tables(html)}

      {:error, html, _warnings} ->
        {:safe, wrap_tables(html)}
    end
  end

  # Wide tables scroll sideways inside their own box instead of squashing the
  # columns (or pushing the whole page wider than a phone screen).
  defp wrap_tables(html) do
    html
    |> String.replace(~r/<table(\s[^>]*)?>/, ~s(<div class="prose-table"><table\\1>))
    |> String.replace("</table>", "</table></div>")
  end

  def strip_front_matter(markdown) when is_binary(markdown) do
    String.replace(markdown, @front_matter, "", global: false)
  end
end
