defmodule ExFuzz.RunnerTest do
  use ExUnit.Case, async: false

  alias ExFuzz.{Engine, Runner}

  defp engine(map_len) do
    {:ok, engine} =
      Engine.new(%{map_len: map_len, max_input_len: 64, rng_seed: 1, seeds: ["AAAA"]})

    engine
  end

  defp solutions do
    receive do
      {:ex_fuzz, :solution, solution} -> [solution | solutions()]
    after
      0 -> []
    end
  end

  test "stops at the first crash and reports the input that caused it" do
    # Crashes on about half the inputs, so reporting the wrong input shows.
    target = fn
      <<byte, _::binary>> when rem(byte, 2) == 1 -> raise "odd"
      _ -> :ok
    end

    stats = Runner.run(engine(1), target, report_to: self(), timeout: 1_000, max_execs: 1_000)

    assert [%{input: input, outcome: {:crash, :error, %RuntimeError{message: "odd"}, _}}] =
             solutions()

    assert_raise RuntimeError, fn -> target.(input) end
    assert stats.engine.solutions == 1
    assert stats.engine.executions < 1_000
  end

  test "max_execs runs the target exactly that many times" do
    runs = :counters.new(1, [])
    target = fn _ -> :counters.add(runs, 1, 1) end

    stats = Runner.run(engine(1), target, report_to: self(), timeout: 1_000, max_execs: 1_000)

    assert :counters.get(runs, 1) == 1_000
    assert stats.engine.executions == 1_000
  end

  test "a timeout also ends the run, as a solution" do
    target = fn _ -> Process.sleep(:infinity) end
    stats = Runner.run(engine(1), target, report_to: self(), timeout: 10, max_execs: 10)
    assert_received {:ex_fuzz, :solution, %{outcome: {:timeout, _}}}
    assert stats.engine.executions == 1
  end

  test "the engine can be reused for another run" do
    engine = engine(1)
    first = Runner.run(engine, fn _ -> :ok end, report_to: self(), timeout: 1_000, max_execs: 10)
    second = Runner.run(engine, fn _ -> :ok end, report_to: self(), timeout: 1_000, max_execs: 10)
    assert {first.engine.executions, second.engine.executions} == {10, 20}
  end

  test "max_time ends the run" do
    stats =
      Runner.run(engine(1), fn _ -> :ok end, report_to: self(), timeout: 1_000, max_time: 100)

    assert stats.elapsed_ms >= 100 and stats.elapsed_ms < 1_000
  end

  test ":stop ends the run" do
    test = self()
    engine = engine(1)

    runner =
      spawn(fn ->
        stats = Runner.run(engine, fn _ -> :ok end, report_to: test, timeout: 1_000)
        send(test, {:done, stats})
      end)

    send(runner, :stop)
    assert_receive {:done, %{engine: %{solutions: 0}}}
  end

  test "leaves no timer messages behind for the caller" do
    target = fn _ -> :ok end
    opts = [report_to: self(), timeout: 1_000, stats_interval: 1]

    # Ends on max_execs with both timers pending, then on its deadline.
    Runner.run(engine(1), target, opts ++ [max_execs: 100, max_time: 50])
    Runner.run(engine(1), target, opts ++ [max_time: 20])

    # Long enough for any timer the runner left behind to fire.
    Process.sleep(100)
    {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, &match?({:timeout, timer, _} when is_reference(timer), &1))
  end

  test "sends stats periodically" do
    Runner.run(engine(1), fn _ -> :ok end,
      report_to: self(),
      timeout: 1_000,
      max_time: 200,
      stats_interval: 20
    )

    assert_received {:ex_fuzz, :stats,
                     %{engine: %{executions: _, corpus: _, solutions: _}, elapsed_ms: _}}

    assert_received {:ex_fuzz, :stats, _}
  end
end
