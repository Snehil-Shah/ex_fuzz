# The probes' cost.
# Run: mix run bench/probe.exs

alias ExFuzz.{Engine, Instrument}

modules = Application.spec(:jason, :modules)
{:ok, %{binaries: binaries, probes: probes}} = Instrument.instrument(modules)
{:ok, _engine} = Engine.new(%{map_len: probes, max_input_len: 4_096, rng_seed: 1, seeds: []})

input =
  Jason.encode!(for i <- 1..100, do: %{"id" => i, "name" => "item #{i}", "tags" => ["a", "b"]})

original = fn _ ->
  for module <- modules, do: {:code.purge(module), :code.load_file(module)}
end

instrumented = fn _ -> :ok = Instrument.load(binaries) end

Benchee.run(%{
  "original" => {fn _ -> Jason.decode!(input) end, before_scenario: original},
  "instrumented" => {fn _ -> Jason.decode!(input) end, before_scenario: instrumented}
})
