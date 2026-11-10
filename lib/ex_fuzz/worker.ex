defmodule ExFuzz.Worker do
  @moduledoc false

  # Fuzzes the target in the current worker node.
  # The coordinator starts that node as `mix test` for one fuzz test.
  # Events are pushed to the coordinator in the origin VM.

  alias ExFuzz.{Engine, Executor, Instrument, Runner}

  @type option ::
          {:test, test()}
          | {:modules, [module()]}
          | {:max_input_len, pos_integer()}
          | {:rng_seed, non_neg_integer()}
          | {:min_heap_size, pos_integer()}
          | Runner.budget()
          | {:stats_interval, pos_integer()}

  @typedoc "Encoded by the coordinator into the worker node's environment."
  @type setting :: option() | {:origin, pid()} | {:io, Process.dest()}

  @typedoc "A fuzz test, by the line it is on or by its name."
  @type test :: {Path.t(), pos_integer() | String.t()}

  @typedoc "The running fuzz test's ExUnit context."
  @type context :: %{
          required(:module) => module(),
          required(:test) => atom(),
          required(:describe_line) => pos_integer() | nil,
          optional(atom()) => term()
        }

  @type result :: :ok | {:solution, Runner.solution()} | {:error, term()}

  @doc """
  Encodes `settings` for the environment variable, as `run/5` takes them.

  Settings:
    * `:origin`, `:test`, `:modules`, `:max_input_len` (required).
    * `:rng_seed` - see `t:ExFuzz.Engine.engine_opts/0`.
    * `t:ExFuzz.Runner.budget/0`, `:min_heap_size`, `:stats_interval` - see `ExFuzz.Runner.run/3`.
    * `:io` - where events are pushed. Defaults to `:user`, the worker node's I/O server.
  """
  @spec encode([setting()]) :: String.t()
  def encode(settings), do: settings |> :erlang.term_to_binary() |> Base.encode64()

  @doc """
  Fuzzes `target`, starting from `seeds`, until it crashes, a budget is spent, or it receives `:stop`.

  `encoded` comes from `encode/1`. `context` is the running ExUnit context.

  Pushes `{:ex_fuzz, :started, %{module: module, test: name}}`, the runner's stats, then the
  solution if there is one, then `{:ex_fuzz, :done, stats}`, or `{:ex_fuzz, :error, reason}`
  if fuzzing couldn't start.
  """
  @spec run(String.t(), context(), [binary()], timeout(), Executor.target()) :: result()
  def run(encoded, context, seeds, timeout, target) do
    settings = encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
    Process.register(self(), __MODULE__)
    forwarder = forwarder(settings)
    send(forwarder, {:ex_fuzz, :started, %{module: context.module, test: context.test}})

    case fuzz(settings, context, seeds, timeout, target, forwarder) do
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

  defp fuzz(settings, context, seeds, timeout, target, forwarder) do
    with :ok <- one_test(Keyword.fetch!(settings, :test), context),
         {:ok, %{binaries: binaries, probes: probes}} <-
           Instrument.instrument(Keyword.fetch!(settings, :modules)),
         {:ok, engine} <- Engine.new(engine_opts(settings, probes, seeds)),
         :ok <- Instrument.load(binaries) do
      runner_opts =
        settings
        |> Keyword.take([:min_heap_size, :max_execs, :max_time, :stats_interval])
        |> Keyword.merge(report_to: forwarder, timeout: timeout)

      Runner.run(engine, target, runner_opts)
    end
  end

  # A `describe` line selects every test in the block.
  defp one_test({_path, line}, %{describe_line: line}), do: {:error, {:describe_line, line}}
  defp one_test(_test, _context), do: :ok

  defp engine_opts(settings, probes, seeds) do
    %{
      map_len: probes,
      max_input_len: Keyword.fetch!(settings, :max_input_len),
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
