defmodule ExFuzz.Runner do
  @moduledoc false

  # Drives the fuzz loop for one target.

  # TODO: Continuous fuzzing mode with crash deduplication.

  alias ExFuzz.{Engine, Executor}

  @default_stats_interval 1_000

  @type solution :: %{input: binary(), outcome: Executor.outcome()}
  @type stats :: %{engine: Engine.stats(), elapsed_ms: non_neg_integer()}
  @type option ::
          Executor.option()
          | {:report_to, Process.dest()}
          | {:max_execs, non_neg_integer()}
          | {:max_time, non_neg_integer()}
          | {:stats_interval, pos_integer()}

  @doc """
  Fuzzes `target` with `engine` until an input crashes or times out,
  a budget is spent, or this process receives `:stop`.

  Sends `{:ex_fuzz, :solution, solution}` for the crashing input and
  `{:ex_fuzz, :stats, stats}` every `:stats_interval` to `:report_to`.

  Returns the final stats.

  Options:
    * `:report_to` (required) - where solutions and stats are sent.
    * `:timeout` (required), `:min_heap_size` - passed to `ExFuzz.Executor.run/3`.
    * `:max_execs`, `:max_time` (milliseconds) - budgets. Without either, runs until `:stop`.
    * `:stats_interval` - milliseconds between stats messages. Defaults to #{@default_stats_interval}.
  """
  @spec run(Engine.engine(), (binary() -> term()), [option()]) :: stats()
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
      execs: 0,
      last: nil
    }

    loop(state, :none)
  end

  defp loop(%{execs: execs, max_execs: execs} = state, previous), do: finish(state, previous)

  defp loop(%{deadline_timer: deadline, stats_timer: stats} = state, previous) do
    receive do
      :stop ->
        finish(state, previous)

      {:timeout, ^deadline, :deadline} ->
        finish(%{state | deadline_timer: nil}, previous)

      {:timeout, ^stats, :stats} ->
        send(state.report_to, {:ex_fuzz, :stats, stats(state)})
        timer = :erlang.start_timer(state.stats_interval, self(), :stats)
        step(%{state | stats_timer: timer}, previous)
    after
      0 -> step(state, previous)
    end
  end

  defp step(state, previous) do
    {input, _verdict} = Engine.step(state.engine, previous)
    outcome = Executor.run(state.target, input, state.executor_opts)
    state = %{state | execs: state.execs + 1, last: {input, outcome}}

    case outcome do
      :ok -> loop(state, :ok)
      _crash_or_timeout -> finish(state, engine_outcome(outcome))
    end
  end

  defp finish(state, :none), do: done(state)

  defp finish(state, previous) do
    state.engine |> Engine.report(previous) |> report_solution(state)
    done(state)
  end

  defp done(state) do
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

  defp report_solution(:solution, %{last: {input, outcome}, report_to: pid}),
    do: send(pid, {:ex_fuzz, :solution, %{input: input, outcome: outcome}})

  defp report_solution(_verdict, _state), do: :ok

  defp stats(state),
    do: %{engine: Engine.stats(state.engine), elapsed_ms: now() - state.started}

  defp engine_outcome({:crash, _, _, _}), do: :crash
  defp engine_outcome({:timeout, _}), do: :timeout

  defp now, do: System.monotonic_time(:millisecond)
end
