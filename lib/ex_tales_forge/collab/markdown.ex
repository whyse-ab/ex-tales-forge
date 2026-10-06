defmodule TalesForge.Collab.Markdown do
  @moduledoc false

  # The importer already splits YAML front matter off before storing bodies;
  # this is a safety net so a body that still carries it never renders it.
  @front_matter ~r/\A\s*---[ \t]*\r?\n.*?\r?\n---[ \t]*(\r?\n|\z)/s

  # First line of the body when it is an ATX H1 ("# Title").
  @leading_h1 ~r/\A\s*#[ \t]+([^\r\n]+)(?:\r?\n|\z)/

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

  @doc """
  Drops a leading `# Heading` when it matches `title`, so a view that already
  shows the title (e.g. as a card heading) doesn't render it a second time.
  Bodies that don't open with that exact H1 are returned unchanged.
  """
  def strip_title_heading(nil, _title), do: nil

  def strip_title_heading(markdown, title) when is_binary(markdown) and is_binary(title) do
    markdown = strip_front_matter(markdown)

    case Regex.run(@leading_h1, markdown) do
      [heading_line, heading] ->
        if String.trim(heading) == String.trim(title) do
          String.replace_prefix(markdown, heading_line, "")
        else
          markdown
        end

      _ ->
        markdown
    end
  end

  def strip_title_heading(markdown, _title), do: markdown
end
