defmodule TalesForge.Survey.SourceTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import TalesForge.SurveyFixtures

  alias TalesForge.Survey.Cache
  alias TalesForge.Survey.Source

  setup do
    snapshot_only()
  end

  test "without a docs checkout or token the priv snapshot is used" do
    assert {:ok, loaded} = Source.load("founder-survey-3")
    assert loaded.source == "snapshot priv/surveys/founder-survey-3.json"
    assert loaded.problems == []
    assert String.length(loaded.sha256) == 64
    assert Source.describe("founder-survey-3") =~ "GITHUB_DOCS_TOKEN not set"
  end

  test "unknown or unsafe ids" do
    assert {:error, ["unknown survey"]} = Source.load("../etc/passwd")
    assert {:error, [message]} = Source.load("no-such-survey")
    assert message =~ "no survey no-such-survey"
  end

  test "a local docs checkout wins and is cached" do
    file = use_docs_dir(survey_json())
    assert {:ok, %{source: "local docs checkout", definition: d}} = Source.load("test-survey")
    assert d.title == "Test survey"
    assert Source.describe("test-survey") =~ "local docs checkout"

    File.write!(file, survey_json(%{"title" => "Edited"}))
    assert {:ok, %{definition: %{title: "Test survey"}}} = Source.load("test-survey")
    assert {:ok, %{definition: %{title: "Edited"}}} = Source.load("test-survey", fresh: true)
  end

  test "a broken docs file falls back to the last good copy, with problems" do
    file = use_docs_dir(survey_json())
    assert {:ok, %{problems: []}} = Source.load("test-survey")

    File.write!(file, ~s({"format": 1}))
    # Expire the good entry so the next load refetches.
    {:fresh, good} = Cache.get({:survey, "test-survey"})
    Cache.put({:survey, "test-survey"}, good, 0)

    assert {:ok, loaded} = Source.load("test-survey")
    assert loaded.definition.title == "Test survey"
    assert Enum.any?(loaded.problems, &(&1 =~ "local docs checkout: id is missing"))
    assert List.last(loaded.problems) =~ "last good copy from local docs checkout"
  end

  test "a broken docs file with no good copy falls back to the snapshot" do
    use_docs_dir("{nope", "founder-survey-3")
    assert {:ok, loaded} = Source.load("founder-survey-3")
    assert loaded.source =~ "snapshot"
    assert Enum.any?(loaded.problems, &(&1 =~ "not valid JSON"))
    assert List.last(loaded.problems) =~ "showing the snapshot"
  end

  test "nothing usable gives every problem" do
    use_docs_dir("{nope")
    assert {:error, problems} = Source.load("test-survey")
    assert Enum.any?(problems, &(&1 =~ "not valid JSON"))
    assert Enum.any?(problems, &(&1 =~ "no survey test-survey"))
  end

  test "a missing local file is reported" do
    dir = Path.join(System.tmp_dir!(), "tf-survey-empty-#{System.unique_integer([:positive])}")
    Application.put_env(:ex_tales_forge, :tales_forge_docs_path, dir)
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :tales_forge_docs_path) end)

    assert {:ok, loaded} = Source.load("founder-survey-3")
    assert hd(loaded.problems) =~ "could not read"
  end

  describe "GitHub" do
    setup do
      Application.put_env(:ex_tales_forge, :github_docs_token, "test-token")
      :ok
    end

    test "reads docs/<id>.json from tales-forge-docs main" do
      Req.Test.stub(Source, fn conn ->
        assert conn.request_path ==
                 "/repos/whyse-ab/tales-forge-docs/contents/docs/test-survey.json"

        assert conn.query_string == "ref=main"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        Req.Test.json(conn, %{
          "content" => Base.encode64(survey_json()),
          "encoding" => "base64",
          "sha" => "abcdef1234567"
        })
      end)

      assert {:ok, loaded} = Source.load("test-survey")
      assert loaded.source == "tales-forge-docs main (blob abcdef1)"
      assert Source.describe("test-survey") =~ "GitHub whyse-ab/tales-forge-docs@main"
    end

    test "HTTP errors fall back to the snapshot" do
      for {status, expected} <- [
            {404, "is not in whyse-ab/tales-forge-docs@main"},
            {500, "HTTP 500"}
          ] do
        Cache.clear()
        Req.Test.stub(Source, &Plug.Conn.send_resp(&1, status, "{}"))
        assert {:ok, loaded} = Source.load("founder-survey-3")
        assert hd(loaded.problems) =~ expected
      end

      Cache.clear()
      Req.Test.stub(Source, &Req.Test.transport_error(&1, :econnrefused))
      assert {:ok, loaded} = Source.load("founder-survey-3")
      assert hd(loaded.problems) =~ "request for docs/founder-survey-3.json failed"

      Cache.clear()
      Req.Test.stub(Source, &Req.Test.json(&1, %{"content" => "!!!", "sha" => "x"}))
      assert {:ok, loaded} = Source.load("founder-survey-3")
      assert hd(loaded.problems) =~ "unexpected encoding"
    end
  end
end
