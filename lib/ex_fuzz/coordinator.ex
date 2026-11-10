defmodule ExFuzz.Coordinator do
  @moduledoc false

  # Runs a fuzz test in a worker node, a child VM running `mix test`.

  alias ExFuzz.{Runner, Worker}

  @crash_dump "_build/ex_fuzz/erl_crash.dump"

  @type option :: {:report_to, Process.dest()} | Worker.option()
  @type result ::
          {:done, Runner.stats()}
          | {:error, :stopped | term()}
          | {:not_started, term()}
          | {:node_down, term()}

  @doc """
  Fuzzes one fuzz target in a new worker node, until the test finishes.

  Relays the test's `{:ex_fuzz, :started | :stats | :solution, _}` events to `:report_to`.

  Options:
    * `:report_to` (required) - where events are relayed.
    * `t:ExFuzz.Worker.option/0` - see `ExFuzz.Worker.encode/1`.
  """
  @spec run([option()]) :: result()
  def run(opts) do
    {report_to, opts} = Keyword.pop!(opts, :report_to)
    test = Keyword.fetch!(opts, :test)
    settings = [origin: self()] ++ opts
    File.mkdir_p!(Path.dirname(@crash_dump))

    {:ok, peer, _node} =
      :peer.start(%{
        connection: :standard_io,
        peer_down: :crash,
        exec: {elixir_bin(~c"elixir"), []},
        env: [
          {~c"MIX_ENV", ~c"test"},
          {~c"EX_FUZZ_WORKER", to_charlist(Worker.encode(settings))},
          {~c"ERL_CRASH_DUMP", to_charlist(Path.expand(@crash_dump))}
        ],
        post_process_args: &mix_test(&1, test)
      })

    ref = Process.monitor(peer)

    try do
      await(peer, ref, report_to, false)
    after
      Process.demonitor(ref, [:flush])
      stop(peer)
    end
  end

  defp elixir_bin(name), do: :filename.join([:code.lib_dir(:elixir), ~c"../../bin", name])

  # Hands peer's own `erl` flags to `elixir --erl`, then runs `mix test` as the program.
  defp mix_test(erl_args, test) do
    erl_args = Enum.join(erl_args, " ")
    args = ["--erl", erl_args, elixir_bin(~c"mix"), "test" | select(test)]
    Enum.map(args, &to_charlist/1)
  end

  defp select({path, line}) when is_integer(line), do: ["#{path}:#{line}"]
  defp select({path, name}), do: [path, "--only", "test:#{name}"]

  defp await(peer, ref, report_to, started?) do
    receive do
      {:ex_fuzz, :done, stats} ->
        await_exit(ref, {:done, stats})

      {:ex_fuzz, :error, reason} ->
        await_exit(ref, {:error, reason})

      {:ex_fuzz, kind, _value} = event ->
        send(report_to, event)
        await(peer, ref, report_to, started? or kind == :started)

      :stop when not started? ->
        {:error, :stopped}

      :stop ->
        :ok = :peer.call(peer, Worker, :stop, [])
        await(peer, ref, report_to, started?)

      {:DOWN, ^ref, :process, ^peer, reason} when not started? ->
        {:not_started, reason}

      {:DOWN, ^ref, :process, ^peer, reason} ->
        {:node_down, reason}
    end
  end

  # Lets `mix test` print its report before the node is stopped.
  defp await_exit(ref, result) do
    receive do
      {:DOWN, ^ref, :process, _peer, _reason} -> result
      :stop -> result
    end
  end

  defp stop(peer) do
    :peer.stop(peer)
  catch
    # The node may already be gone.
    :exit, :noproc -> :ok
  end
end
