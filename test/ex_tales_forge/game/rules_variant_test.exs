defmodule TalesForge.Game.RulesVariantTest do
  @moduledoc """
  The rules text follows the session's behaviour variant: the default variant
  states the learn-from-failure, sleep-on-it growth rule (decision
  2026-10-09, after the LP-for-attempt rule of 2026-10-07); the baseline
  variant keeps the #64 text it was written against, via
  `<root>/variants/baseline/rules/`.
  """
  use ExUnit.Case, async: true

  alias TalesForge.Game.Prompts

  for adventure <- ["tin_valley", "crossroads_ledger", nil] do
    test "#{inspect(adventure)}: default states the new rule, baseline the #64 rule" do
      default = Prompts.load_rules(unquote(adventure))
      baseline = Prompts.load_rules(unquote(adventure), "baseline")

      assert default =~ "you learn only from failure, only in the skill you failed"
      assert default =~ "Banked LP are resolved on a long rest"
      refute default =~ "Master 16+: 15"
      assert baseline =~ "Master 16+: 15"
      refute baseline =~ "Banked LP are resolved on a long rest"
    end
  end

  test "only the overridden files differ; every heading stays" do
    default = Prompts.load_rules("tin_valley")
    baseline = Prompts.load_rules("tin_valley", "baseline")
    headings = &Regex.scan(~r{^### [\w/]+\.md$}m, &1)

    assert headings.(default) == headings.(baseline)
    assert Prompts.load_rules("tin_valley", "default") == default

    economy = fn text -> text |> String.split("### economy.md") |> List.last() end

    assert economy.(default) |> String.split("\n---\n") |> hd() ==
             economy.(baseline) |> String.split("\n---\n") |> hd()
  end
end
