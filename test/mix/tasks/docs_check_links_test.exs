defmodule Mix.Tasks.Docs.CheckLinksTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Docs.CheckLinks

  setup do
    dir = Path.join(System.tmp_dir!(), "exdoc_links_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "dist"))
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp page(dir, name, body),
    do: File.write!(Path.join(dir, name), "<html><body>#{body}</body></html>")

  test "a site whose internal links all resolve passes", %{dir: dir} do
    page(
      dir,
      "index.html",
      ~s(<a href="readme.html">Readme</a><script src="dist/app.js"></script>)
    )

    page(dir, "readme.html", """
    <h2 id="setup">Setup</h2>
    <a href="#setup">here</a> <a href="Foo.html#bar/1">bar</a> <a href="./">home</a>
    <a href="https://github.com/whyse-ab/ex-tales-forge/blob/main/mix.exs#L1">source</a>
    <a href="mailto:team@example.com">mail</a> <a href="search.html?q=foo&amp;x=1">search</a>
    """)

    page(dir, "Foo.html", ~s(<section id="bar/1"></section>))
    page(dir, "search.html", "")
    File.write!(Path.join(dir, "dist/app.js"), "")

    File.write!(
      Path.join(dir, "dist/sidebar_items-ABC.js"),
      ~s(sidebarNodes={"modules":[{"id":"Foo","sections":[],"nodeGroups":[{"nodes":[{"anchor":"bar/1"}]}]}]})
    )

    File.write!(
      Path.join(dir, "dist/search_data-ABC.js"),
      ~s(searchData={"items":[{"ref":"Foo.html#bar/1"},{"ref":"readme.html#setup"}]})
    )

    assert CheckLinks.check(dir) == []
  end

  test "missing files, anchors and links out of /admin/code-docs are reported", %{dir: dir} do
    page(dir, "readme.html", """
    <a href="PRODUCT.md">product</a> <a href="../text-forge">old app</a>
    <a href="#nowhere">anchor</a> <script src="docs_config.js"></script>
    <a href="/admin/code-docs/readme.html">absolute, fine</a>
    """)

    File.write!(
      Path.join(dir, "dist/search_data-ABC.js"),
      ~s(searchData={"items":[{"ref":"readme.html#gone-heading"}]})
    )

    assert [
             %{page: "readme.html", link: "#nowhere", reason: ~s(no id "nowhere" in readme.html)},
             %{page: "readme.html", link: "../text-forge", reason: reason},
             %{page: "readme.html", link: "PRODUCT.md", reason: "no file PRODUCT.md"},
             %{page: "readme.html", link: "docs_config.js", reason: "no file docs_config.js"},
             %{page: "search", link: "readme.html#gone-heading"}
           ] = CheckLinks.check(dir)

    assert reason =~ "/admin/text-forge, outside /admin/code-docs/"
  end

  test "the task fails with the list, or passes quietly", %{dir: dir} do
    page(dir, "index.html", ~s(<a href="gone.html">gone</a>))

    assert_raise Mix.Error, ~r/1 broken link/, fn ->
      ExUnit.CaptureIO.capture_io(:stderr, fn -> CheckLinks.run([dir]) end)
    end

    page(dir, "gone.html", "")
    assert ExUnit.CaptureIO.capture_io(fn -> CheckLinks.run([dir]) end) =~ "resolves"
  end
end
