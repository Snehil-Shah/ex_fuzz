defmodule ExFuzz.Worker do
  @moduledoc false

  # Runs the fuzz loop inside the worker, and pushes every event
  # to the coordinator's listener in the origin VM.

  alias ExFuzz.{Engine, Instrument, Runner}

  @type option ::
          {:target, {module(), atom()}}
          | {:modules, [module()]}
          | {:max_input_len, pos_integer()}
          | {:rng_seed, non_neg_integer()}
          | {:seeds, [binary()]}
          | Runner.option()

  @doc """
  Starts the worker, registered as `#{inspect(__MODULE__)}` so `:stop` can reach it.

  `listener` gets the runner's events, then `{:ex_fuzz, :done, stats}` or `{:ex_fuzz, :error, reason}`.

  Options:
    * `:target` (required) - `{module, function}`, called with each input.
    * `:modules` (required) - modules to instrument.
    * `:max_input_len` (required), `:rng_seed`, `:seeds` - passed to `ExFuzz.Engine.new/1`.
    * `:timeout` (required), `:min_heap_size`, `:max_execs`, `:max_time`, `:stats_interval` - passed to `ExFuzz.Runner.run/3`.
  """
  @spec start(pid(), [option()]) :: :ok
  def start(listener, opts) do
    worker = spawn(fn -> run(listener, opts) end)
    Process.register(worker, __MODULE__)
    :ok
  end

  defp run(listener, opts) do
    forwarder = forwarder(listener)
    {tag, value} = setup_and_run(opts, forwarder)
    send(forwarder, {:ex_fuzz, tag, value})
  end

  defp setup_and_run(opts, forwarder) do
    {module, function} = Keyword.fetch!(opts, :target)

    with {:ok, %{binaries: binaries, probes: probes}} <-
           Instrument.instrument(Keyword.fetch!(opts, :modules)),
         {:ok, engine} <- Engine.new(engine_opts(opts, probes)),
         :ok <- Instrument.load(binaries) do
      runner_opts =
        opts
        |> Keyword.take([:timeout, :min_heap_size, :max_execs, :max_time, :stats_interval])
        |> Keyword.put(:report_to, forwarder)

      {:done, Runner.run(engine, &apply(module, function, [&1]), runner_opts)}
    end
  end

  defp engine_opts(opts, probes) do
    %{
      map_len: probes,
      max_input_len: Keyword.fetch!(opts, :max_input_len),
      rng_seed: Keyword.get(opts, :rng_seed),
      seeds: Keyword.get(opts, :seeds, [])
    }
  end

  # Relays events in order, and reports the worker if it dies before finishing.
  defp forwarder(listener) do
    worker = self()

    spawn(fn ->
      ref = Process.monitor(worker)
      forward(listener, ref)
    end)
  end

  defp forward(listener, ref) do
    receive do
      {:DOWN, ^ref, :process, _, :normal} ->
        :ok

      {:DOWN, ^ref, :process, _, reason} ->
        push(listener, {:ex_fuzz, :error, {:worker_down, reason}})

      event ->
        push(listener, event)
        forward(listener, ref)
    end
  end

  # The fuzz node's group leader is the peer's I/O server,
  # which forwards `{:message, to, msg}` to `to` in the origin VM.
  # WARNING: Undocumented `:peer` behaviour (taken from OTP's own `peer_SUITE`).
  defp push(listener, event), do: send(Process.group_leader(), {:message, listener, event})
end
