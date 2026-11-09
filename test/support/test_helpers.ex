defmodule ExFuzz.TestHelpers do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias ExFuzz.Engine

  @engine_defaults %{map_len: 1, max_input_len: 64, rng_seed: 1, seeds: ["AAAA"]}

  @doc "An engine with a fresh coverage map. `overrides` replace `#{inspect(@engine_defaults)}`."
  def engine(overrides \\ []) do
    {:ok, engine} = Engine.new(Map.merge(@engine_defaults, Map.new(overrides)))
    engine
  end

  @doc "Puts back the original, uninstrumented code of `modules`."
  def restore(modules) do
    for module <- List.wrap(modules) do
      :code.purge(module)
      {:module, ^module} = :code.load_file(module)
    end
  end

  @doc "Restores `modules` when the test ends."
  def restore_on_exit(modules), do: on_exit(fn -> restore(modules) end)
end
