# End-to-end throughput.
# Run: mix run bench/throughput.exs

alias ExFuzz.{Engine, Instrument, Runner}

{:ok, %{binaries: binaries, probes: probes}} =
  Instrument.instrument(Application.spec(:jason, :modules))

:ok = Instrument.load(binaries)

execs = 10_000

Benchee.run(%{
  "#{execs} inputs" => fn ->
    {:ok, engine} =
      Engine.new(%{map_len: probes, max_input_len: 4_096, rng_seed: 1, seeds: ["{}", "[1]"]})

    {:done, _stats} =
      Runner.run(engine, &Jason.decode/1, report_to: self(), timeout: 1_000, max_execs: execs)
  end
})
