defmodule Mix.Tasks.CodeHeat.OverheadTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "prints the overhead of each workload and of the session" do
    Mix.shell(Mix.Shell.IO)
    output = capture_io(fn -> Mix.Tasks.CodeHeat.Overhead.run(["--runs", "50"]) end)
    assert output =~ "small: off="
    assert output =~ "page: off="
    assert output =~ "ns/call"
    assert output =~ "session: start="
  end
end
