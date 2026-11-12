defmodule ExFuzz.Worker do
  @moduledoc false

  # Fuzzes the target in the current worker node.
  # The coordinator starts that node as `mix test` for one fuzz test.
  # Events are pushed to the coordinator in the origin VM.

  alias ExFuzz.{Engine, Executor, Instrument, Runner, Scope}

  # libFuzzer's default.
  # TODO: Configurable
  @default_max_input_len 4_096

  @typedoc """
  A fuzzing option, passed on by the coordinator.

    * `:max_input_len` - in bytes. Defaults to #{@default_max_input_len}.
    * `:rng_seed` - see `t:ExFuzz.Engine.opts/0`.
    * `t:ExFuzz.Runner.budget/0`, `:min_heap_size`, `:stats_interval` - see `ExFuzz.Runner.run/3`.
  """
  @type option ::
          {:max_input_len, pos_integer()}
          | {:rng_seed, non_neg_integer()}
          | {:min_heap_size, pos_integer()}
          | Runner.budget()
          | {:stats_interval, pos_integer()}

  @typedoc """
  Encoded by the coordinator into the worker node's environment.

    * `t:option/0` - the fuzzing options.
    * `:origin` (required) - the coordinator, in the origin VM: who receives the events.
    * `:io` - the local process that relays events to `:origin`. Defaults to `:user`, the worker node's I/O server.
  """
  @type setting :: option() | {:origin, pid()} | {:io, Process.dest()}

  @typedoc "The running fuzz test's ExUnit context."
  @type context :: %{
          required(:module) => module(),
          required(:test) => atom(),
          optional(atom()) => term()
        }

  @type result :: :ok | {:solution, Runner.solution()} | {:error, term()}

  @doc "Encodes settings for the environment variable."
  @spec encode_settings([setting()]) :: String.t()
  def encode_settings(settings), do: settings |> :erlang.term_to_binary() |> Base.encode64()

  @doc "Decodes settings from `encode_settings/1`."
  @spec decode_settings(String.t()) :: [setting()]
  def decode_settings(encoded), do: encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])

  @doc """
  The end-to-end fuzzing session.

  Arguments:
    * `encoded` - the settings, from `encode_settings/1`.
    * `context` - the running ExUnit context.
    * `seeds` - the inputs fuzzing starts from.
    * `additional_modules` - instrumented along with the project's, see `ExFuzz.Scope.modules/1`.
    * `timeout` - milliseconds before an input is killed.
    * `target` - fuzzed until it crashes, a budget is spent, or the worker receives `:stop`.

  Pushes `{:ex_fuzz, :started, %{module: module, test: name}}`, the runner's stats, then the
  solution if there is one, then `{:ex_fuzz, :done, stats}`, or `{:ex_fuzz, :error, reason}`
  if fuzzing couldn't start.
  """
  @spec run(String.t(), context(), [binary()], [module()], timeout(), Executor.target()) ::
          result()
  def run(encoded, context, seeds, additional_modules, timeout, target) do
    settings = decode_settings(encoded)
    Process.register(self(), __MODULE__)
    forwarder = forwarder(settings)
    send(forwarder, {:ex_fuzz, :started, %{module: context.module, test: context.test}})

    case fuzz(settings, seeds, additional_modules, timeout, target, forwarder) do
      {:done, stats} ->
        send(forwarder, {:ex_fuzz, :done, stats})
        :ok

      {:solution, solution, stats} ->
        send(forwarder, {:ex_fuzz, :solution, solution})
        send(forwarder, {:ex_fuzz, :done, stats})
        {:solution, solution}

      {:error, reason} ->
        send(forwarder, {:ex_fuzz, :error, reason})
        {:error, reason}
    end
  after
    Process.unregister(__MODULE__)
  end

  @doc "Stops the running fuzz loop."
  @spec stop() :: :ok
  def stop do
    if worker = Process.whereis(__MODULE__), do: send(worker, :stop)
    :ok
  end

  defp fuzz(settings, seeds, additional_modules, timeout, target, forwarder) do
    with {:ok, modules} <- scope(additional_modules),
         {:ok, %{binaries: binaries, probes: probes}} <- Instrument.instrument(modules),
         {:ok, engine} <- Engine.new(engine_opts(settings, probes, seeds)),
         :ok <- Instrument.load(binaries) do
      runner_opts =
        settings
        |> Keyword.take([:min_heap_size, :max_execs, :max_time, :stats_interval])
        |> Keyword.merge(report_to: forwarder, timeout: timeout)

      Runner.run(engine, target, runner_opts)
    end
  end

  defp scope(additional_modules) do
    case Scope.modules(additional_modules) do
      [] -> {:error, :nothing_to_instrument}
      modules -> {:ok, modules}
    end
  end

  defp engine_opts(settings, probes, seeds) do
    %{
      map_len: probes,
      max_input_len: Keyword.get(settings, :max_input_len, @default_max_input_len),
      rng_seed: Keyword.get(settings, :rng_seed),
      seeds: seeds
    }
  end

  defp forwarder(settings) do
    worker = self()
    io = Keyword.get(settings, :io, :user)
    origin = Keyword.fetch!(settings, :origin)

    spawn(fn ->
      ref = Process.monitor(worker)
      forward(io, origin, ref)
    end)
  end

  defp forward(io, origin, ref) do
    receive do
      # Comes after every event the worker sent.
      {:DOWN, ^ref, :process, _, _} ->
        :ok

      event ->
        # WARNING: Undocumented `:peer` behaviour: its I/O server (`:user`)
        # forwards `{:message, to, msg}` to `to` in the origin VM.
        send(io, {:message, origin, event})
        forward(io, origin, ref)
    end
  end
end
