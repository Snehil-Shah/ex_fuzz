defmodule ExFuzz.TestHelpers do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias ExFuzz.{Config, Engine}

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

  @doc "Clears corpus and cache for `module`."
  def clear_corpus(module) do
    for key <- [:corpus_dir, :cache_dir] do
      File.rm_rf!(Path.join(Config.get(key), inspect(module)))
    end
  end

  @doc """
  Like `ExUnit.CaptureIO.with_io/1`, for worker nodes started inside `fun`.
  """
  def with_node_io(fun) do
    {:ok, string_io} = StringIO.open("")
    group_leader = spawn_link(fn -> accept_setopts(string_io) end)
    original = Process.group_leader()
    Process.group_leader(self(), group_leader)

    result =
      try do
        fun.()
      after
        Process.group_leader(self(), original)
      end

    {:ok, {_input, output}} = StringIO.close(string_io)
    {result, output}
  end

  defp accept_setopts(string_io) do
    receive do
      {:io_request, from, ref, {:setopts, _opts}} -> send(from, {:io_reply, ref, :ok})
      {:io_request, _from, _ref, _request} = request -> send(string_io, request)
    end

    accept_setopts(string_io)
  end
end
