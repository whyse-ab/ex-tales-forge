defmodule TalesForge.Board.ApiTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Board
  alias TalesForge.Board.Api

  setup do
    {:ok, idea} = Board.create_idea("ada@example.com", %{"title" => "Brenna remembers regulars"})
    {:ok, idea} = Board.vote(idea, "ada@example.com", 1)
    %{idea: idea}
  end

  test "index and show", %{idea: idea} do
    assert {200, %{"ideas" => [card]}} = Api.handle(:index, :case, %{"column" => "ideas"})
    assert card["id"] == idea.id
    assert card["net_votes"] == 1
    assert card["url"] =~ "/team#idea-#{idea.id}"

    assert {200, %{"title" => "Brenna remembers regulars"}} =
             Api.handle(:show, :bobby, %{"id" => idea.id})

    assert {404, _} = Api.handle(:show, :case, %{"id" => "nope"})
    assert {404, _} = Api.handle(:show, :case, %{})
  end

  test "Case pulls, refines and hands over; others can't refine", %{idea: idea} do
    id = idea.id

    assert {200, %{"column" => "refining"}} =
             Api.handle(:move, :case, %{"id" => id, "to" => "refining"})

    assert {422, %{"error" => "Only Case refines cards."}} =
             Api.handle(:refine, :bobby, %{"id" => id})

    assert {200, %{"refined" => true}} =
             Api.handle(:refine, :case, %{
               "id" => id,
               "details" => "d",
               "open_questions" => [],
               "rough_cost" => "M",
               "verdict" => "feasible_with_caveats"
             })

    assert {200, %{"column" => "check"}} =
             Api.handle(:move, :case, %{"id" => id, "to" => "check"})

    assert {422, %{"error" => "Only a founder can move a card to Building."}} =
             Api.handle(:move, :case, %{"id" => id, "to" => "building"})
  end

  test "links, comments and Gentry's pass", %{idea: idea} do
    assert {422, %{"error" => err}} =
             Api.handle(:link, :bobby, %{"id" => idea.id, "kind" => "pr", "url" => "nope"})

    assert err =~ "url"

    assert {200, %{"links" => [_]}} =
             Api.handle(:link, :bobby, %{"id" => idea.id, "kind" => "pr", "url" => "https://x/1"})

    assert {200, %{"comments" => [%{"body" => body}]}} =
             Api.handle(:comment, :gentry, %{
               "id" => idea.id,
               "verdict" => "pass",
               "body" => "Clean."
             })

    assert body =~ Board.gentry_pass()
  end
end
