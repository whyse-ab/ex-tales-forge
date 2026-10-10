defmodule TalesForge.Board.ImagesTest do
  use TalesForge.DataCase, async: false

  import TalesForge.ImageFixtures

  alias TalesForge.Board
  alias TalesForge.Board.Api
  alias TalesForge.Images.Image
  alias TalesForge.Repo

  @ada "ada@example.com"

  setup do
    Application.put_env(:ex_tales_forge, :pr_feed_token, "feed-token")
    Application.put_env(:ex_tales_forge, :board_req_options, plug: {Req.Test, __MODULE__})
    System.put_env("GIT_SHA", "run1")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/repos/whyse-ab/ex-tales-forge/pulls/1" ->
          Req.Test.json(conn, %{"merged" => true, "merge_commit_sha" => "m1abcdef"})

        "/repos/whyse-ab/ex-tales-forge/compare/m1abcdef...run1" ->
          Req.Test.json(conn, %{"status" => "ahead"})
      end
    end)

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :pr_feed_token)
      Application.delete_env(:ex_tales_forge, :board_req_options)
      System.delete_env("GIT_SHA")
    end)

    {:ok, idea} = Board.create_idea(@ada, %{"title" => "Show the bug", "body" => "Here."})
    {:ok, idea: idea}
  end

  test "a founder adds images with a note; the API JSON has the links", %{idea: idea} do
    assert {:ok, idea} = Board.add_images(idea, @ada, [png(), png()], "The map is blank")
    assert [%Image{note: "The map is blank", data: nil} = image, _] = idea.images

    assert %{"images" => [json, _]} = Api.card(idea)
    assert json["api_url"] == "https://tales-forge.fly.dev/internal/images/#{image.id}"
    assert json["uploader"] == @ada

    assert {200, %{"images" => [_, _]}} = Api.handle(:show, :gentry, %{"id" => idea.id})
  end

  test "a bad file adds no image", %{idea: idea} do
    assert {:error, "Add a PNG, JPEG or WebP image."} =
             Board.add_images(idea, @ada, [png(), gif()], nil)

    assert {:error, "Add an image first."} = Board.add_images(idea, @ada, [], nil)
    assert Repo.aggregate(Image, :count) == 0
  end

  test "the images go when the card reaches Done", %{idea: idea} do
    {:ok, idea} = Board.add_images(idea, @ada, [png()], nil)
    {:ok, idea} = Board.vote(idea, @ada, 1)
    {:ok, idea} = Board.move(idea, {:founder, @ada}, "refining")

    {:ok, idea} =
      Board.refine(idea, %{
        "details" => "Track it.",
        "open_questions" => [],
        "rough_cost" => "S",
        "verdict" => "feasible"
      })

    {:ok, idea} = Board.move(idea, {:bot, :case}, "check")
    {:ok, idea} = Board.move(idea, {:founder, @ada}, "building")
    assert [_] = idea.images

    {:ok, idea} =
      Board.add_link(idea, "bot:bobby", %{
        "kind" => "pr",
        "url" => "https://github.com/x/y/pull/1"
      })

    assert {:ok, %{column: "done", images: []}} = Board.move(idea, {:bot, :bobby}, "done")
    assert Repo.aggregate(Image, :count) == 0
  end
end
