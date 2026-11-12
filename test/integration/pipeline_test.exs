defmodule ExFuzz.Integration.PipelineTest do
  use ExUnit.Case, async: false

  # Instrumentation, engine, executor and runner together, on real code.

  import ExFuzz.TestHelpers

  alias ExFuzz.{Instrument, Runner}

  test "coverage finds a planted bug, and the input crashes the original code too" do
    original = SampleDep.Planted.module_info(:md5)
    {:ok, %{binaries: binaries, probes: probes}} = Instrument.instrument([SampleDep.Planted])
    engine = engine(map_len: probes)
    restore_on_exit(SampleDep.Planted)
    :ok = Instrument.load(binaries)

    assert {:solution,
            %{
              input: "FUZZ" <> _ = input,
              outcome: {:crash, :error, %RuntimeError{message: "planted"}, _}
            }, stats} =
             Runner.run(engine, &SampleDep.Planted.check/1,
               report_to: self(),
               timeout: 1_000,
               max_time: 5_000
             )

    assert stats.engine.solutions == 1

    restore(SampleDep.Planted)
    assert SampleDep.Planted.module_info(:md5) == original
    assert_raise RuntimeError, "planted", fn -> SampleDep.Planted.check(input) end
  end

  test "without instrumentation, the same search does not find it" do
    # Same engine settings, no probes: the fuzzer is blind to how close an input gets to "FUZZ".
    assert {:done, stats} =
             Runner.run(engine(), &SampleDep.Planted.check/1,
               report_to: self(),
               timeout: 1_000,
               max_execs: 200_000
             )

    assert stats.engine.executions == 200_000
  end
end
