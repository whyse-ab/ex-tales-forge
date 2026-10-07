defmodule TalesForge.LLMStructuredOutputTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.Schemas.{GMStructuredResponse, HandlerResult, PlayerAction, SingleAction}
  alias TalesForge.GameSessions
  alias TalesForge.LLM

  @system "GM SYSTEM"
  @user "RULES AND STATE"

  setup do
    # Created on the mock provider, so the opening scene makes no request.
    {:ok, session} = GameSessions.create_session(%{name: "Structured GM"})
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")

    on_exit(fn ->
      System.delete_env("LLM_PROVIDER")
      System.delete_env("XAI_API_KEY")
    end)

    %{session: session}
  end

  # Replies with `contents` in order and sends each raw request body to the test.
  defp stub_replies(contents) do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> contents end)

    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, body})
      content = Agent.get_and_update(agent, fn [c | rest] -> {c, rest} end)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 20}
      })
    end)
  end

  defp gm_turn(session) do
    LLM.complete_turn(
      @system,
      @user,
      %PlayerAction{overall_intent: "look around", action: %SingleAction{action_type: :observe}},
      %HandlerResult{handler: "observe"},
      1,
      session_id: session.id
    )
  end

  defp next_request do
    assert_received {:request, body}
    {body, Jason.decode!(body)}
  end

  test "GM call uses strict json_schema with narrative as the first property", %{
    session: session
  } do
    stub_replies([~s({"narrative":"The lamp gutters.","gm_notes":"n"})])

    assert {:ok, %GMStructuredResponse{narrative: "The lamp gutters."}} = gm_turn(session)

    {raw, request} = next_request()

    assert %{"type" => "json_schema", "json_schema" => format} = request["response_format"]
    assert format["name"] == "gm_turn"
    assert format["strict"] == true
    assert format["schema"]["required"] == ["narrative"]

    # Key order on the wire: narrative is the first property of the schema.
    assert raw =~ ~s("properties":{"narrative":)

    assert ["narrative" | _] =
             raw |> Jason.decode!(objects: :ordered_objects) |> schema_keys()

    # The schema is no longer pasted into the prompt.
    [_system, %{"content" => user}] = request["messages"]
    refute user =~ "Return JSON matching this schema"
  end

  test "invalid JSON retry re-sends the original messages with a correction appended", %{
    session: session
  } do
    stub_replies(["not json {", ~s({"narrative":"Second try."})])

    assert {:ok, %GMStructuredResponse{narrative: "Second try."}} = gm_turn(session)

    {_raw, first} = next_request()
    {_raw, retry} = next_request()

    assert_retry_order(first, retry)
  end

  test "a reply without narrative fails validation and is retried the same way", %{
    session: session
  } do
    stub_replies([~s({"narrative":"  ","gm_notes":"x"}), ~s({"narrative":"Now with prose."})])

    assert {:ok, %GMStructuredResponse{narrative: "Now with prose."}} = gm_turn(session)

    {_raw, first} = next_request()
    {_raw, retry} = next_request()

    assert_retry_order(first, retry)
  end

  test "two invalid replies give up after one retry", %{session: session} do
    stub_replies(["nope", "still nope"])

    assert {:error, :invalid_json} = gm_turn(session)
    assert_received {:request, _}
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "non-GM calls keep json_object with the schema pasted at the end", %{session: session} do
    stub_replies([~s({"action":"I wave."})])

    assert {:ok, %{"action" => "I wave."}} =
             LLM.complete_persona("persona", "what now?", session_id: session.id)

    {_raw, request} = next_request()
    assert request["response_format"] == %{"type" => "json_object"}
    [_system, %{"content" => user}] = request["messages"]
    assert user =~ ~r/^what now\?\n\nReturn JSON matching this schema:/
  end

  test "persona retry also appends instead of prepending", %{session: session} do
    stub_replies(["???", ~s({"action":"I wave."})])

    assert {:ok, _} = LLM.complete_persona("persona", "what now?", session_id: session.id)

    {_raw, first} = next_request()
    {_raw, retry} = next_request()
    assert_retry_order(first, retry)
  end

  defp assert_retry_order(first, retry) do
    original = first["messages"]
    assert [%{"role" => "system"}, %{"role" => "user"}] = original

    # Identical prefix: every original message, byte for byte, in the same order...
    assert Enum.take(retry["messages"], length(original)) == original

    # ...then exactly one short correction, appended last as a user message.
    assert [%{"role" => "user", "content" => correction}] =
             Enum.drop(retry["messages"], length(original))

    assert correction =~ "not valid JSON"
    assert String.length(correction) < 200
    refute correction =~ @user

    # Same request otherwise (model, schema, conv id routing all unchanged).
    assert Map.delete(retry, "messages") == Map.delete(first, "messages")
  end

  defp schema_keys(%Jason.OrderedObject{} = request) do
    %Jason.OrderedObject{values: values} =
      request["response_format"]["json_schema"]["schema"]["properties"]

    Enum.map(values, &elem(&1, 0))
  end
end
