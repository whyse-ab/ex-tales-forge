defmodule TalesForge.RuntimePrivPathsTest do
  # Regression guard: in a release, priv lives under lib/ex_tales_forge-<vsn>/priv and
  # _build does not exist, so a priv path captured in a module attribute at compile time
  # points nowhere (new games crashed on prod with "adventure pack missing").
  # Tests run from _build, so they can't reproduce that layout; scan the source instead.
  use ExUnit.Case, async: true

  @compile_time_priv ~r/^\s*@\w+\s.*(:code\.priv_dir|Application\.app_dir)/

  test "no module attribute in lib/ builds a path from priv_dir/app_dir at compile time" do
    offenders =
      for file <- Path.wildcard("lib/**/*.{ex,exs}"),
          {line, no} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@compile_time_priv, line),
          do: "#{file}:#{no}: #{String.trim(line)}"

    assert offenders == [],
           "resolve priv paths at runtime (a function), not in a module attribute:\n" <>
             Enum.join(offenders, "\n")
  end
end
