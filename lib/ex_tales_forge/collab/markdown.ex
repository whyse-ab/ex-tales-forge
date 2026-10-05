defmodule TalesForge.Collab.Markdown do
  @moduledoc false

  def to_html(nil), do: {:safe, ""}
  def to_html(""), do: {:safe, ""}

  def to_html(markdown) when is_binary(markdown) do
    case Earmark.as_html(markdown, escape: false, compact_output: true) do
      {:ok, html, _warnings} ->
        {:safe, html}

      {:error, html, _warnings} ->
        {:safe, html}
    end
  end
end
