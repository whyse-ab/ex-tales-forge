defmodule TalesForge.CodeHeat.SamplerTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.CodeHeat
  alias TalesForge.CodeHeat.Sampler
  alias TalesForge.CodeHeat.Tracer

  defmodule Target do
    @moduledoc false
    def work(x), do: x + 1
  end

  setup do
    on_exit(fn -> Application.delete_env(:ex_tales_forge, CodeHeat) end)
  end

  test "the sampler does not start when the heat map is off" do
    assert Sampler.start_link(name: :code_heat_off) == :ignore
  end

  test "the tracer counts calls and stops cleanly" do
    {:ok, session} = Tracer.start([Target])
    Enum.each(1..100, &Target.work/1)

    assert [{Target, :work, 1, 100, time_us}] =
             session
             |> Tracer.read([Target, NoSuchModule])
             |> Enum.filter(&(elem(&1, 1) == :work))

    assert time_us >= 0
    assert :ok = Tracer.stop(session)
    assert :ok = Tracer.stop(session)
  end

  test "the sampler reads, writes one sample and starts from zero" do
    pid = start_supervised!({Sampler, name: :code_heat_test, modules: [Target], force: true})
    Ecto.Adapters.SQL.Sandbox.allow(TalesForge.Repo, self(), pid)

    Enum.each(1..5, &Target.work/1)
    send(pid, :read)
    Enum.each(1..5, &Target.work/1)

    assert {:ok, snapshot} = Sampler.sample_now(:code_heat_test)
    assert [%{"function" => "work/1", "calls" => 10}] = snapshot.rows
    assert snapshot.modules == 1

    send(pid, :sample)
    send(pid, :other)
    _ = :sys.get_state(pid)
    assert %{totals: totals} = :sys.get_state(pid)
    assert totals == %{}

    stop_supervised!(Sampler)
  end
end
