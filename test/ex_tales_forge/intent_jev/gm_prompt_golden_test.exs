defmodule TalesForge.IntentJev.GmPromptGoldenTest do
  @moduledoc """
  The GM prompt of a whole turn (player text in, GM request out) is byte-identical
  whether `INTENT_JEV` is off or shadow, and for the baseline variant whatever
  the flag says.

  The golden files in `test/fixtures/prompts/gm_turn/` were written from
  `main` before Jev intent was wired in (this test, without the shadow case, run
  there with `UPDATE_GM_TURN_GOLDEN=1`). The off case proves the default path is
  unchanged, the shadow case that the shadow Jev read (stubbed here, it runs
  inline in tests) changes nothing the GM sees, and the baseline case that the
  frozen arm ignores the flag. The LLM is stubbed with `Req.Test` (xAI wire
  shape) and the dice are seeded, so no network and no keys.
  """
  use TalesForge.DataCase, async: false

  import Ecto.Query
  import TalesForge.PlaytestHelpers, only: [stub_llm: 1]

  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo

  @dir Path.expand("../../fixtures/prompts/gm_turn", __DIR__)
  @text "I ask the innkeeper about the road north"

  setup do
    endpoints = Application.get_env(:jev, :endpoints)
    mode = Application.get_env(:ex_tales_forge, :intent_jev)

    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      Application.put_env(:jev, :endpoints, endpoints)
      restore(:intent_jev, mode)
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
    end)

    test_pid = self()

    stub_llm(fn
      :gm, user, system ->
        send(test_pid, {:gm_prompt, "--- system ---\n#{system}\n--- user ---\n#{user}"})
        :default

      _kind, _user, _system ->
        :default
    end)

    # Any Jev intent read (shadow) gets a fixed benign answer.
    Application.put_env(:jev, :endpoints,
      intent: [base_url: "https://api.typesafe.ai", api_key: "test-key", model: "jev-1.13.0"]
    )

    Req.Test.stub(Jev.HTTP, fn conn ->
      send(test_pid, :jev_called)

      Jev.Test.respond(conn,
        action: :speak,
        skill: :none,
        later: :none,
        safety: :benign,
        confidence: %{action: 0.9, safety: 0.97}
      )
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:ex_tales_forge, key)
  defp restore(key, value), do: Application.put_env(:ex_tales_forge, key, value)

  for adventure <- ~w(tin_valley crossroads_ledger) do
    @tag :gm_turn_golden
    test "#{adventure}: INTENT_JEV off plays the golden GM prompt" do
      Application.put_env(:ex_tales_forge, :intent_jev, :off)
      check_golden(unquote(adventure), "default", gm_prompt(unquote(adventure), "default", nil))
      refute_received :jev_called
    end

    @tag :gm_turn_golden
    test "#{adventure} (baseline): INTENT_JEV=on is ignored, the golden GM prompt plays" do
      Application.put_env(:ex_tales_forge, :intent_jev, :on)

      check_golden(
        unquote(adventure),
        "baseline",
        gm_prompt(unquote(adventure), "baseline", "on")
      )

      refute_received :jev_called
    end

    test "#{adventure}: INTENT_JEV shadow plays the same GM prompt and only logs Jev" do
      Application.put_env(:ex_tales_forge, :intent_jev, :shadow)
      {prompt, session_id} = gm_prompt_and_session(unquote(adventure), "default", nil)
      check_golden(unquote(adventure), "default", prompt)

      assert_received :jev_called

      purposes =
        Repo.all(
          from c in "ai_calls",
            where: c.game_session_id == type(^session_id, :binary_id),
            select: c.purpose
        )

      assert "intent_shadow" in purposes
      assert "turn.intent_shadow" in purposes
    end
  end

  defp gm_prompt(adventure, variant, intent_jev),
    do: adventure |> gm_prompt_and_session(variant, intent_jev) |> elem(0)

  defp gm_prompt_and_session(adventure, variant, intent_jev) do
    attrs =
      %{name: "GM turn golden", adventure_id: adventure, variant: variant}
      |> then(&if(intent_jev, do: Map.put(&1, :intent_jev, intent_jev), else: &1))

    {:ok, session} = GameSessions.create_session(attrs)
    :rand.seed(:exsss, {7, 11, 13})
    assert {:ok, %{status: :processing}} = GameSessions.submit_message(session.id, @text)
    assert_received {:gm_prompt, prompt}
    {normalise(prompt, session.id), session.id}
  end

  defp check_golden(adventure, variant, actual) do
    suffix = if variant == "default", do: "", else: ".#{variant}"
    path = Path.join(@dir, "#{adventure}#{suffix}.txt")

    if System.get_env("UPDATE_GM_TURN_GOLDEN") in ~w(1 true) do
      File.mkdir_p!(@dir)
      File.write!(path, actual)
    end

    assert actual == File.read!(path),
           "the GM prompt for #{adventure} (#{variant}) changed; diff #{path} against a fresh render"
  end

  defp normalise(text, session_id) do
    text
    |> String.replace(session_id, "<SESSION>")
    |> String.replace(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "<UUID>")
    |> String.replace(~r/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?Z?/, "<TS>")
  end
end
