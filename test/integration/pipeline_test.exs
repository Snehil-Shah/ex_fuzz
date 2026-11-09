defmodule ExFuzz.Integration.PipelineTest do
  use ExUnit.Case, async: false

  # Instrumentation, engine, executor and runner together, on real code.

  alias ExFuzz.{Engine, Fixtures, Instrument, Runner}

  defp engine(map_len) do
    {:ok, engine} =
      Engine.new(%{map_len: map_len, max_input_len: 64, rng_seed: 1, seeds: ["AAAA"]})

    engine
  end

  defp restore(module) do
    :code.purge(module)
    {:module, ^module} = :code.load_file(module)
  end

  test "coverage finds a planted bug, and the input crashes the original code too" do
    original = Fixtures.Planted.module_info(:md5)
    {:ok, %{binaries: binaries, probes: probes}} = Instrument.instrument([Fixtures.Planted])
    engine = engine(probes)
    on_exit(fn -> restore(Fixtures.Planted) end)
    :ok = Instrument.load(binaries)

    stats =
      Runner.run(engine, &Fixtures.Planted.check/1,
        report_to: self(),
        timeout: 1_000,
        max_time: 5_000
      )

    assert_received {:ex_fuzz, :solution,
                     %{
                       input: "FUZZ" <> _ = input,
                       outcome: {:crash, :error, %RuntimeError{message: "planted"}, _}
                     }}

    assert stats.engine.solutions == 1

    restore(Fixtures.Planted)
    assert Fixtures.Planted.module_info(:md5) == original
    assert_raise RuntimeError, "planted", fn -> Fixtures.Planted.check(input) end
  end

  test "without instrumentation, the same search does not find it" do
    # Same engine settings, no probes: the fuzzer is blind to how close an input gets to "FUZZ".
    stats =
      Runner.run(engine(1), &Fixtures.Planted.check/1,
        report_to: self(),
        timeout: 1_000,
        max_execs: 200_000
      )

    refute_received {:ex_fuzz, :solution, _}
    assert stats.engine.executions == 200_000
  end
end
