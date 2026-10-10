defmodule TalesForge.ImagesTest do
  use TalesForge.DataCase, async: false

  import TalesForge.ImageFixtures

  alias TalesForge.Chat
  alias TalesForge.Images
  alias TalesForge.Images.Image
  alias TalesForge.Repo

  doctest TalesForge.Images

  @fredrik "fredrik@whyse.se"

  describe "store and validation" do
    test "a PNG goes in; a list query does not load the bytes" do
      {:ok, m} = Chat.post(@fredrik, "Look")

      assert {:ok, image} =
               Images.store({:message, m.id}, png(), %{uploader: @fredrik, note: " x "})

      assert image.content_type == "image/png"
      assert image.byte_size == byte_size(png())
      assert image.note == "x"

      assert [%Image{data: nil}] = Images.for_messages([m.id])[m.id]
      assert %Image{data: data} = Images.get_with_data(image.id)
      assert data == png()
    end

    test "the content decides the type, not the file name" do
      {:ok, m} = Chat.post(@fredrik, "Look")

      assert {:error, "Add a PNG, JPEG or WebP image."} =
               Images.store({:message, m.id}, gif(), %{uploader: @fredrik})

      assert {:error, "Add a PNG, JPEG or WebP image."} =
               Images.store({:message, m.id}, "<svg onload=alert(1)>", %{uploader: @fredrik})

      assert Repo.aggregate(Image, :count) == 0
    end

    test "an empty file and a file over 5 MB are refused" do
      assert {:error, "The file is empty."} = Images.validate("")
      big = png() <> :binary.copy(<<0>>, Images.max_bytes())
      assert {:error, "Add an image of 5 MB or less."} = Images.validate(big)
      assert :ok = Images.validate(png())
    end

    test "an unknown or malformed id gives nil" do
      assert Images.get_with_data("nope") == nil
      assert Images.get_with_data(Ecto.UUID.generate()) == nil
    end
  end

  describe "chat images" do
    test "a message with an image can have an empty text; the bots get the links" do
      assert {:ok, m} = Chat.post(@fredrik, "", images: [png()])
      assert m.body == ""
      assert [%Image{content_type: "image/png"} = image] = m.images

      assert %{"images" => [json]} = Chat.to_json(m)
      assert json["url"] == "https://tales-forge.fly.dev/team/images/#{image.id}"
      assert json["api_url"] == "https://tales-forge.fly.dev/internal/images/#{image.id}"
      assert json["content_type"] == "image/png"

      assert {200, %{"messages" => [%{"images" => [%{"id" => id}]}]}} =
               Chat.api(:index, :case, %{})

      assert id == image.id
    end

    test "a bad file stores nothing and shows the reason" do
      assert {:error, cs} = Chat.post(@fredrik, "Look", images: [gif()])
      assert "Add a PNG, JPEG or WebP image." in errors_on(cs).body
      assert Chat.recent() == []
    end

    test "deleting a message deletes its images" do
      {:ok, m} = Chat.post(@fredrik, "Look", images: [png()])
      Repo.delete!(m)
      assert Repo.aggregate(Image, :count) == 0
    end
  end
end
