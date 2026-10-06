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
end
