defmodule ExFuzz.Runner do
  @moduledoc false

  # Drives the fuzz loop for one target.

  # TODO: Continuous fuzzing mode with crash deduplication.

  alias ExFuzz.{Engine, Executor}

  @default_refresh_interval 1_000

  @type solution :: %{input: binary(), outcome: Executor.outcome()}
  @type stats :: %{engine: Engine.stats(), elapsed_ms: non_neg_integer()}
  @type result :: {:done, stats()} | {:solution, solution(), stats()}
  @type budget :: {:max_execs, non_neg_integer()} | {:max_time, non_neg_integer()}
  @type option ::
          Executor.option()
          | {:report_to, Process.dest()}
          | {:corpus_to, Process.dest()}
          | budget()
          | {:refresh_interval, pos_integer()}

  @doc """
  Fuzzes `target` with `engine` until an input crashes or times out,
  a budget is spent, or this process receives `:stop`.

  Every `:refresh_interval`, sends `{:ex_fuzz, :stats, stats}` to `:report_to` and new inputs to `:corpus_to`.

  Returns the final stats, with the crashing input if there was one.

  Options:
    * `:report_to` (required) - where stats are sent.
    * `:corpus_to` - where inputs that reach new coverage are sent, as `{:ex_fuzz, :corpus, inputs}`.
    * `:timeout` (required), `:min_heap_size` - passed to `ExFuzz.Executor.run/3`.
    * `t:budget/0` - `:max_execs`, or `:max_time` in milliseconds. Without either, runs until `:stop`.
    * `:refresh_interval` - milliseconds between refreshes. Defaults to #{@default_refresh_interval}.
  """
  @spec run(Engine.engine(), Executor.target(), [option()]) :: result()
  def run(engine, target, opts) do
    max_time = Keyword.get(opts, :max_time)
    refresh_interval = Keyword.get(opts, :refresh_interval, @default_refresh_interval)

    state = %{
      engine: engine,
      target: target,
      executor_opts: Keyword.take(opts, [:timeout, :min_heap_size]),
      report_to: Keyword.fetch!(opts, :report_to),
      corpus_to: Keyword.get(opts, :corpus_to),
      found: [],
      max_execs: Keyword.get(opts, :max_execs),
      refresh_interval: refresh_interval,
      deadline_timer: max_time && :erlang.start_timer(max_time, self(), :deadline),
      refresh_timer: :erlang.start_timer(refresh_interval, self(), :refresh),
      started: now(),
      execs: 0
    }

    loop(state)
  end

  defp loop(%{execs: execs, max_execs: execs} = state), do: {:done, close(state)}

  defp loop(%{deadline_timer: deadline, refresh_timer: refresh} = state) do
    receive do
      :stop ->
        {:done, close(state)}

      {:timeout, ^deadline, :deadline} ->
        {:done, close(%{state | deadline_timer: nil})}

      {:timeout, ^refresh, :refresh} ->
        send(state.report_to, {:ex_fuzz, :stats, stats(state)})
        timer = :erlang.start_timer(state.refresh_interval, self(), :refresh)
        run_input(flush(%{state | refresh_timer: timer}))
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
      {:ok, :corpus} -> loop(%{state | found: [input | state.found]})
      {:ok, _verdict} -> loop(state)
      {_failure, :solution} -> {:solution, %{input: input, outcome: outcome}, close(state)}
      {_failure, _verdict} -> {:done, close(state)}
    end
  end

  # Hands the inputs found since the last flush to `:corpus_to`.
  defp flush(%{found: []} = state), do: state

  defp flush(state) do
    if state.corpus_to, do: send(state.corpus_to, {:ex_fuzz, :corpus, state.found})
    %{state | found: []}
  end

  # Flushes, cancels the timers and returns the final stats.
  defp close(state) do
    flush(state)
    cancel(state.refresh_timer)
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
