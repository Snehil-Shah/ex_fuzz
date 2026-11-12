defmodule ExFuzz.Runner do
  @moduledoc false

  # Drives the fuzz loop for one target.

  # TODO: Continuous fuzzing mode with crash deduplication.

  alias ExFuzz.{Engine, Executor}

  @default_stats_interval 1_000

  @type solution :: %{input: binary(), outcome: Executor.outcome()}
  @type stats :: %{engine: Engine.stats(), elapsed_ms: non_neg_integer()}
  @type result :: {:done, stats()} | {:solution, solution(), stats()}
  @type budget :: {:max_execs, non_neg_integer()} | {:max_time, non_neg_integer()}
  @type option ::
          Executor.option()
          | {:report_to, Process.dest()}
          | budget()
          | {:stats_interval, pos_integer()}

  @doc """
  Fuzzes `target` with `engine` until an input crashes or times out,
  a budget is spent, or this process receives `:stop`.

  Sends `{:ex_fuzz, :stats, stats}` to `:report_to` every `:stats_interval`.

  Returns the final stats, with the crashing input if there was one.

  Options:
    * `:report_to` (required) - where stats are sent.
    * `:timeout` (required), `:min_heap_size` - passed to `ExFuzz.Executor.run/3`.
    * `t:budget/0` - `:max_execs`, or `:max_time` in milliseconds. Without either, runs until `:stop`.
    * `:stats_interval` - milliseconds between stats messages. Defaults to #{@default_stats_interval}.
  """
  @spec run(Engine.engine(), Executor.target(), [option()]) :: result()
  def run(engine, target, opts) do
    max_time = Keyword.get(opts, :max_time)
    stats_interval = Keyword.get(opts, :stats_interval, @default_stats_interval)

    state = %{
      engine: engine,
      target: target,
      executor_opts: Keyword.take(opts, [:timeout, :min_heap_size]),
      report_to: Keyword.fetch!(opts, :report_to),
      max_execs: Keyword.get(opts, :max_execs),
      stats_interval: stats_interval,
      deadline_timer: max_time && :erlang.start_timer(max_time, self(), :deadline),
      stats_timer: :erlang.start_timer(stats_interval, self(), :stats),
      started: now(),
      execs: 0
    }

    loop(state)
  end

  defp loop(%{execs: execs, max_execs: execs} = state), do: {:done, close(state)}

  defp loop(%{deadline_timer: deadline, stats_timer: stats} = state) do
    receive do
      :stop ->
        {:done, close(state)}

      {:timeout, ^deadline, :deadline} ->
        {:done, close(%{state | deadline_timer: nil})}

      {:timeout, ^stats, :stats} ->
        send(state.report_to, {:ex_fuzz, :stats, stats(state)})
        timer = :erlang.start_timer(state.stats_interval, self(), :stats)
        run_input(%{state | stats_timer: timer})
    after
      0 -> run_input(state)
    end
  end

  defp run_input(state) do
    input = Engine.next(state.engine)
    outcome = Executor.run(state.target, input, state.executor_opts)
    state = %{state | execs: state.execs + 1}

    # The first failure ends the run.
    case {outcome, Engine.report(state.engine, engine_outcome(outcome))} do
      {:ok, _verdict} -> loop(state)
      {_failure, :solution} -> {:solution, %{input: input, outcome: outcome}, close(state)}
      {_failure, _verdict} -> {:done, close(state)}
    end
  end

  # Cancels the timers and returns the final stats.
  defp close(state) do
    cancel(state.stats_timer)
    cancel(state.deadline_timer)
    stats(state)
  end

  defp cancel(nil), do: :ok

  defp cancel(timer) do
    if Process.cancel_timer(timer) == false do
      # Consume the already fired message.
      receive do
        {:timeout, ^timer, _kind} -> :ok
      end
    end
  end

  defp stats(state),
    do: %{engine: Engine.stats(state.engine), elapsed_ms: now() - state.started}

  defp engine_outcome(:ok), do: :ok
  defp engine_outcome({:crash, _, _, _}), do: :crash
  defp engine_outcome({:timeout, _}), do: :timeout

  defp now, do: System.monotonic_time(:millisecond)
end
