defmodule TalesForge.Game.GesturesTest do
  @moduledoc """
  GM gesture tracking by pattern (decision 2026-10-08 "GM tics: track recent
  gestures as off-limits; drop phrase-by-phrase bans"): the tics the
  post-rework playtest found are caught in their variants, and plain prose is
  left alone.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias TalesForge.Game.Gestures

  doctest Gestures
  doctest Gestures.Forms

  defp keys(text), do: text |> Gestures.extract() |> Enum.map(& &1.key)

  describe "extract/1 catches the playtest tics in their variants" do
    test "wiping hands" do
      assert keys("Brenna wipes her floury hands on her apron.") == ["wipe:hand"]
      assert keys("Wiping her hands, Brenna laughs.") == ["wipe:hand"]
      assert keys("He wiped his hands clean.") == ["wipe:hand"]
    end

    test "leaning on an elbow or a hip, or on the bar" do
      assert keys("She leans an elbow on the bar.") == ["lean:elbow"]
      assert keys("Brenna, leaning on one elbow, grins.") == ["lean:elbow"]
      assert keys("She leans a hip against the bar.") == ["lean:hip"]
      assert keys("He leans on the counter.") == ["lean:counter"]
    end

    test "Cobb's weight and knuckles" do
      assert keys("Cobb shifts his weight, knuckles whitening on the club.") ==
               ["shift:weight", "knuckle:whiten"]
    end

    test "eyes and heads" do
      assert keys("Rusk's eyes narrow just a fraction.") == ["eye:narrow"]
      assert keys("Rusk narrows his eyes.") == ["narrow:eye"]
      assert keys("She tilts her head toward the door.") == ["tilt:head"]
    end

    test "the mug across the scarred oak, and the hearth" do
      assert keys("She slides a fresh mug across the scarred oak.") == [
               "slide:mug",
               "scarred-oak"
             ]

      assert keys("The hearth crackles behind him.") == ["hearth-crackle"]
    end

    test "plain prose has no gestures" do
      assert keys("The road west is muddy, and the pines close in after a mile.") == []
      assert keys("\"Two coppers,\" Brenna says. \"Stew's hot.\"") == []
    end
  end

  test "recent/1 lists the newest narration first and caps the list" do
    narrations = [
      "She wipes her hands.",
      "Cobb shifts his weight.",
      "She wipes her hands again and tilts her head."
    ]

    assert Gestures.recent(narrations) |> Enum.map(& &1.key) ==
             ["wipe:hand", "tilt:head", "shift:weight"]

    many =
      for part <- ~w(hand finger palm fist arm elbow hip head chin jaw brow eye lip neck),
          do: "She rubs her #{part}."

    assert length(Gestures.recent(many)) == 12
    assert Gestures.recent([nil, ""]) == []
  end

  test "prompt_section/1 lists the spent gestures, or nothing" do
    section = Gestures.prompt_section(Gestures.recent(["Brenna wipes her hands."]))

    assert section ==
             "## Gestures already used (recent turns)\n- wipes her hands\n" <>
               "These are spent: do not use them again, nor the same motion with the same body part or prop."

    assert Gestures.prompt_section(nil) == nil
  end

  test "log_repeats/3 logs each spent gesture the GM used anyway" do
    spent = Gestures.recent(["Cobb shifts his weight."])

    log =
      capture_log(fn ->
        assert [%{key: "shift:weight"}] =
                 Gestures.log_repeats("Cobb shifting his weight, growls.", spent,
                   session: "s1",
                   turn: 5
                 )
      end)

    assert log =~ "gm gesture repeated session=s1 turn=5 key=shift:weight"

    assert capture_log(fn -> assert [] = Gestures.log_repeats("Cobb growls.", spent, []) end) ==
             ""
  end
end
