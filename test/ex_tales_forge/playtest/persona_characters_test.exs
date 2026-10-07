defmodule TalesForge.Playtest.PersonaCharactersTest do
  use ExUnit.Case, async: true

  alias TalesForge.CharacterCreation
  alias TalesForge.Playtest.{PersonaCharacters, Personas}

  doctest PersonaCharacters

  test "every persona has a pick, and every pick is a valid character in every module" do
    picks = PersonaCharacters.picks()

    assert picks |> Map.keys() |> Enum.sort() ==
             Personas.list() |> Enum.map(& &1.id) |> Enum.sort()

    for {id, pick} <- picks, module <- ~w(tin_valley crossroads_ledger) do
      assert {:ok, character} = PersonaCharacters.build(id, module), "#{id} in #{module}"
      assert character["name"] == pick["name"]
      assert character["race"] == pick["race"]
      assert character["class"] == pick["class"]
      assert character["creation"]["base_stats"] == pick["base_stats"]
      assert character["creation"]["points_spent"] <= 75
      assert is_binary(pick["concept"]) and pick["concept"] != ""
    end
  end

  test "a persona plays the same character every run" do
    {:ok, first} = PersonaCharacters.build("paul", "tin_valley")
    {:ok, again} = PersonaCharacters.build("paul", "tin_valley")
    assert first == again
    assert first["id"] == CharacterCreation.slug("Corvin Ashdown")
  end

  test "the picks follow the personas" do
    # Ronny min-maxes; nobody else maxes a stat.
    {:ok, ronny} = PersonaCharacters.build("ronny", "tin_valley")
    assert %{"STR" => 18, "CON" => 18} = ronny["stats"]

    for id <- ~w(hawk paul lotta lars) do
      {:ok, c} = PersonaCharacters.build(id, "tin_valley")
      assert Enum.max(Map.values(c["stats"])) <= 17, id
    end

    {:ok, paul} = PersonaCharacters.build("paul", "tin_valley")
    assert paul["skills"]["persuasion"] == 7
  end

  test "every pick spends its whole skill budget within the skill rules" do
    for {id, pick} <- PersonaCharacters.picks() do
      {:ok, c} = PersonaCharacters.build(id, "tin_valley")
      assert Map.take(c["skills"], Map.keys(pick["skills"])) == pick["skills"], id
      assert c["creation"]["occupation"] == pick["occupation"], id
      assert map_size(c["skills"]) >= 6, id
      assert Enum.count(c["skills"], fn {_s, l} -> l > 5 end) in 1..2, id

      budget =
        if c["race"] == "human", do: 30, else: if(c["race"] == "half_elf", do: 28, else: 25)

      free_refund = if id == "lars", do: 3, else: 0
      assert c["creation"]["skill_points_spent"] == budget + free_refund, id
    end
  end

  test "describes the character the persona made, and rejects unknown personas" do
    assert PersonaCharacters.describe(PersonaCharacters.pick("lars")) =~
             "You created this character yourself: Taren Swiftbrook, an elf ranger, a former hunter."

    assert PersonaCharacters.build("nobody", "tin_valley") == {:error, :no_pick}
    assert PersonaCharacters.pick("nobody") == nil
  end
end
