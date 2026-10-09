defmodule TalesForge.Game.GmProseRulesTest do
  @moduledoc """
  The GM's prose rules after the Jev baseline (decision 2026-10-07, "How the
  GM plays Brenna"): no default echo of the player's line, a rare deliberate
  echo as the one exception, and no "on the house" by default. Stock gestures
  are no longer banned phrase by phrase: the gestures of recent turns are
  listed as spent (`TalesForge.Game.Gestures`). The default variant only; the baseline prompts and the
  pre-rework Brenna stay as they were.
  """
  use ExUnit.Case, async: true

  alias TalesForge.Game.Prompts

  @banned [
    "tilts her head",
    "on the house",
    "hands on her apron",
    "wipes her hands",
    "leans on the counter"
  ]

  test "the default GM prompt forbids restating the player's line" do
    gm = Prompts.gm_system()

    assert gm =~ "React, do not restate"
    assert gm =~ "Never open by echoing, quoting or paraphrasing"
    assert gm =~ "used rarely: echoing the last two or three words"
    refute gm =~ "Do not repeat the player's words back"
  end

  test "the default GM prompt rules out default generosity" do
    assert Prompts.gm_system() =~ ~s(nothing is "on the house" by default)
  end

  # Decision 2026-10-08 "GM tics: track recent gestures as off-limits; drop
  # phrase-by-phrase bans" (TalesForge.Game.Gestures).
  test "the default GM prompt spends recent gestures instead of banning phrases" do
    gm = Prompts.gm_system()

    refute gm =~ "Banned stock phrases"
    for phrase <- @banned -- ["on the house"], do: refute(gm =~ ~s("#{phrase}"))
    assert gm =~ ~s|Sometimes the per-turn state has "Gestures already used (recent turns)"|
    assert gm =~ "nor the same motion with the same body part or prop"
  end

  test "the baseline GM prompt is unchanged by this rule" do
    baseline = Prompts.gm_system("baseline")

    refute baseline =~ "React, do not restate"
    for phrase <- @banned, do: refute(baseline =~ phrase)
  end

  test "Brenna charges her prices; the baseline Brenna is untouched" do
    root = Path.join(:code.priv_dir(:ex_tales_forge), "adventures/tin_valley")
    brenna = File.read!(Path.join(root, "npcs/innkeep.md"))
    baseline = File.read!(Path.join(root, "variants/baseline/npcs/innkeep.md"))

    assert brenna =~ "a free plate is earned"
    refute brenna =~ "Kind and generous with civil guests"
    refute baseline =~ "a free plate is earned"
  end
end
