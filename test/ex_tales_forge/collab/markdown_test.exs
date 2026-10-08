defmodule TalesForge.Collab.MarkdownTest do
  use ExUnit.Case, async: true

  alias TalesForge.Collab.Markdown

  describe "strip_title_heading/2" do
    test "drops a leading H1 that matches the title" do
      assert Markdown.strip_title_heading("# Roadmap 2027\n\nBody text.", "Roadmap 2027") ==
               "\nBody text."
    end

    test "drops it after front matter and leading blank lines" do
      md = "---\ntitle: x\n---\n\n# Roadmap\nBody"
      assert Markdown.strip_title_heading(md, "Roadmap") == "Body"
    end

    test "keeps a leading H1 that differs from the title" do
      md = "# Something else\n\nBody"
      assert Markdown.strip_title_heading(md, "Roadmap") == md
    end

    test "keeps bodies that don't open with an H1" do
      md = "Intro\n\n# Roadmap\n\n## Section"
      assert Markdown.strip_title_heading(md, "Roadmap") == md
      assert Markdown.strip_title_heading("## Roadmap\nBody", "Roadmap") == "## Roadmap\nBody"
    end

    test "handles nil bodies" do
      assert Markdown.strip_title_heading(nil, "Roadmap") == nil
    end
  end

  describe "to_html/1" do
    defp html(md), do: md |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

    test "does not render raw HTML from the markdown" do
      out =
        html("""
        Hi <script>alert(1)</script> and <img src=x onerror="alert(1)">

        <div onclick="steal()">block</div>
        """)

      refute out =~ "<script"
      refute out =~ "<img"
      refute out =~ "<div onclick"
      assert out =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert out =~ "&lt;img src=x onerror="
    end

    test "renders GFM tables inside the scroll wrapper" do
      out = html("| A | B |\n|---|---|\n| 1 | 2 |\n")

      assert out =~ ~s(<div class="prose-table"><table>)
      assert out =~ "<th>A</th>"
      assert out =~ "<td>2</td>"
      assert out =~ "</table></div>"
    end

    test "keeps mermaid fences as escaped code the hook can read" do
      out = html(~s(```mermaid\nflowchart TD\n  B["Build:<br/>bot opens PR"] --> F\n```\n))

      assert out =~ ~s(<pre><code class="language-mermaid">flowchart TD)
      assert out =~ "B[&quot;Build:&lt;br/&gt;bot opens PR&quot;] --&gt; F"
    end

    test "renders headings, links, lists and inline code" do
      out = html("## Plan\n\n- see [personas](personas.md)\n- `mix test`\n")

      # GitHub-style heading ids, so `#plan` links written for GitHub work here.
      assert out =~ ~s(<h2 id="plan">Plan)
      assert out =~ ~s(<a href="personas.md">personas</a>)
      assert out =~ "<li><code>mix test</code></li>"
    end

    test "drops front matter and handles empty input" do
      out = html("---\ntitle: x\n---\n# Doc\n")

      refute out =~ "title: x"
      assert out =~ ~s(<h1 id="doc">Doc)
      assert html("") == ""
      assert html(nil) == ""
    end

    test "links: rewrites every link and image URL" do
      {:safe, out} =
        Markdown.to_html("[a](personas.md) ![b](images/x.png) https://example.com",
          links: &("/r/" <> &1)
        )

      assert out =~ ~s(<a href="/r/personas.md">a</a>)
      assert out =~ ~s(<img src="/r/images/x.png" alt="b" />)
      assert out =~ ~s(<a href="/r/https://example.com">)
    end
  end
end
