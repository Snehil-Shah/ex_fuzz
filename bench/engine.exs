# The engine's cost per input.
# Run: mix run bench/engine.exs

alias ExFuzz.Engine

{:ok, engine} = Engine.new(%{map_len: 1, max_input_len: 4_096, rng_seed: 1, seeds: ["{}"]})

Benchee.run(%{
  "next + report" => fn ->
    Engine.next(engine)
    Engine.report(engine, :ok)
  end
})
