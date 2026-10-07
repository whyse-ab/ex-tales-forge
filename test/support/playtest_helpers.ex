defmodule TalesForge.PlaytestHelpers do
  @moduledoc "Stubbed LLM and run helpers for playtest tests. No real AI calls."

  import ExUnit.Assertions

  alias TalesForge.Playtest.Runner

  @gm_reply %{
    "narrative" => "The lamp gutters as the innkeeper eyes you.",
    "gm_notes" => "SECRET-GM-NOTE"
  }

  def await(run_id) do
    result = Runner.await(run_id, 10_000, 20)
    wait_until(fn -> Task.Supervisor.children(TalesForge.Playtest.Supervisor) == [] end)
    result
  end

  def wait_until(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("timed out waiting")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  # Answers every LLM call like xAI would, 2000 micro-USD each. `reply.(kind, user)`
  # (or `reply.(kind, user, system)`) returns the JSON for that call, or :default.
  def stub_llm(reply) do
    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      %{"messages" => messages} = request = Jason.decode!(body)

      system =
        messages |> Enum.filter(&(&1["role"] == "system")) |> Enum.map_join("\n", & &1["content"])

      user =
        messages |> Enum.filter(&(&1["role"] == "user")) |> Enum.map_join("\n", & &1["content"])

      kind = kind(system, user, request)

      content =
        case if(is_function(reply, 3), do: reply.(kind, user, system), else: reply.(kind, user)) do
          :default -> Jason.encode!(default_reply(kind))
          {:raw, text} -> text
          map -> Jason.encode!(map)
        end

      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => content}}
        ],
        "usage" => %{
          "prompt_tokens" => 2000,
          "completion_tokens" => 100,
          "cost_in_usd_ticks" => 20_000_000
        }
      })
    end)

    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
  end

  defp kind(system, user, request) do
    cond do
      system =~ "You are the judge" -> :scorer
      system =~ "You are a playtest bot" -> :persona
      user =~ "Validated player action" -> :gm
      get_in(request, ["response_format", "json_schema", "name"]) == "narration" -> :scene
      user =~ "overall_intent" -> :intent
      true -> :scene
    end
  end

  def judge_reply do
    %{
      "scores" => [
        %{"criterion" => 1, "score" => 4, "evidence" => "T1: \"Evening!\""},
        %{"criterion" => 2, "score" => nil, "evidence" => "no rolls happened"},
        %{"criterion" => 3, "score" => 2, "evidence" => "T1: the innkeeper eyes you"},
        %{"criterion" => 4, "score" => 9, "evidence" => "out of range"}
      ],
      "rationale" => "The GM read the in-character line but the bluff barely mattered."
    }
  end

  defp default_reply(:scorer), do: judge_reply()
  defp default_reply(:persona), do: %{"action" => "I look around the inn.", "option_id" => nil}
  defp default_reply(:gm), do: @gm_reply

  defp default_reply(:scene),
    do: %{"location_name" => "Valley Inn", "narrative" => "Rain drums on the inn's shutters."}

  defp default_reply(:intent) do
    %{
      "overall_intent" => "look around",
      "actions" => [
        %{"action_type" => "observe", "target" => nil, "parameters" => %{"skill" => "insight"}}
      ],
      "primary_index" => 0,
      "confidence" => 0.95,
      "needs_clarification" => false
    }
  end

  def put_caps(caps), do: Application.put_env(:ex_tales_forge, :ai_spend_caps, caps)
end
