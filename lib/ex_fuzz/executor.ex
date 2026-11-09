defmodule ExFuzz.Executor do
  @moduledoc false

  # Runs one input in a fresh process, the way ExUnit runs each test.

  # Reduce GC pressure with a bigger starting heap.
  # The number was decided with some benchmarking on real targets.
  @default_min_heap_size 1_048_576

  @type outcome ::
          :ok
          | {:crash, kind :: term(), reason :: term(), Exception.stacktrace()}
          | {:timeout, Exception.stacktrace()}
  @type option :: {:timeout, timeout()} | {:min_heap_size, pos_integer()}

  @doc """
  Runs `target.(input)` in a fresh process.

  Options:
    * `:timeout` (required) - milliseconds before the input is killed.
    * `:min_heap_size` - starting heap of the input process, in words. Defaults to #{@default_min_heap_size}.
  """
  @spec run((binary() -> term()), binary(), [option()]) :: outcome()
  def run(target, input, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    min_heap_size = Keyword.get(opts, :min_heap_size, @default_min_heap_size)

    {pid, ref} =
      Process.spawn(fn -> exit({:done, call(target, input)}) end, [
        :monitor,
        min_heap_size: min_heap_size
      ])

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> outcome(pid, reason)
    after
      timeout -> kill(pid, ref)
    end
  end

  defp call(target, input) do
    target.(input)
    :ok
  catch
    kind, reason -> {:crash, kind, reason, __STACKTRACE__}
  end

  defp outcome(_pid, {:done, outcome}), do: outcome
  # Killed by an exit signal before returning, e.g. from a linked process.
  defp outcome(pid, reason), do: {:crash, {:EXIT, pid}, reason, []}

  # Takes the stack trace before killing, so the report shows where the input hung.
  defp kill(pid, ref) do
    stacktrace = Process.info(pid, :current_stacktrace)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        case stacktrace do
          {:current_stacktrace, stacktrace} -> {:timeout, stacktrace}
          # It finished right at the deadline.
          nil -> outcome(pid, reason)
        end
    end
  end
end
