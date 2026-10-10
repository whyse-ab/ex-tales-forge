defmodule TalesForge.Board.TagsTest do
  use TalesForge.DataCase, async: true

  alias TalesForge.Board
  alias TalesForge.Board.Tags

  doctest Tags

  test "filter keeps the cards with all selected tags" do
    {:ok, a} = Board.create_idea("max@example.com", %{"title" => "Boats"})
    {:ok, a} = Board.add_tag(a, "max@example.com", "sea")
    {:ok, b} = Board.create_idea("bot:case", %{"title" => "Maps"})
    {:ok, b} = Board.add_tag(b, "max@example.com", "sea")

    assert Tags.of(a) == ["max", "sea"]
    assert Tags.of(b) == ["sea"]
    assert Tags.filter([a, b], ["sea"]) == [a, b]
    assert Tags.filter([a, b], ["sea", "max"]) == [a]
    assert Tags.in_use([a, b]) == ["max", "sea"]
  end

  test "tags are deduplicated and bots add no tags" do
    {:ok, a} = Board.create_idea("max@example.com", %{"title" => "Boats"})
    {:ok, a} = Board.add_tag(a, "max@example.com", "Sea")
    {:ok, a} = Board.add_tag(a, "max@example.com", " sea ")
    {:ok, a} = Board.add_tag(a, "max@example.com", "MAX")
    assert a.tags == ["sea"]
    assert {:error, _} = Board.add_tag(a, "bot:case", "ui")
    assert {:ok, %{tags: []}} = Board.remove_tag(a, "max@example.com", "sea")
  end

  test "the bot API card JSON has the tags" do
    {:ok, a} = Board.create_idea("max@example.com", %{"title" => "Boats"})
    {:ok, a} = Board.add_tag(a, "max@example.com", "sea")
    json = TalesForge.Board.Api.card(a)
    assert json["tags"] == ["max", "sea"]
    assert json["free_tags"] == ["sea"]
  end
end
