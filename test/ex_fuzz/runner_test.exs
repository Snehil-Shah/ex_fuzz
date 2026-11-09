defmodule ExFuzz.RunnerTest do
  use ExUnit.Case, async: false

  alias ExFuzz.{Engine, Fixtures, Instrument, Runner}

  defp engine(map_len, seeds \\ ["AAAA"]) do
    {:ok, engine} = Engine.new(%{map_len: map_len, max_input_len: 64, rng_seed: 1, seeds: seeds})
    engine
  end

  # Instrument and load `module` over a fresh engine.
  defp instrumented_engine(module) do
    {:ok, %{binaries: binaries, probes: probes}} = Instrument.instrument([module])
    engine = engine(probes)

    on_exit(fn ->
      :code.purge(module)
      {:module, ^module} = :code.load_file(module)
    end)

    :ok = Instrument.load(binaries)
    engine
  end

  defp solutions do
    receive do
      {:ex_fuzz, :solution, solution} -> [solution | solutions()]
    after
      0 -> []
    end
  end

  test "finds a planted bug and reports the crashing input" do
    engine = instrumented_engine(Fixtures.Planted)
    test = self()

    {runner, ref} =
      spawn_monitor(fn ->
        Runner.run(engine, &Fixtures.Planted.check/1, report_to: test, timeout: 1_000)
      end)

    assert_receive {:ex_fuzz, :solution,
                    %{
                      input: "FUZZ" <> _,
                      outcome: {:crash, :error, %RuntimeError{message: "planted"}, _}
                    }},
                   5_000

    send(runner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
  end

  test "each solution is reported with its own input" do
    # Crashes on about half the inputs, so pairing a verdict with the wrong input shows.
    target = fn
      <<byte, _::binary>> when rem(byte, 2) == 1 -> raise "odd"
      _ -> :ok
    end

    Runner.run(engine(1), target, report_to: self(), timeout: 1_000, max_execs: 1_000)

    assert [_ | _] = solutions = solutions()

    for %{input: input, outcome: outcome} <- solutions do
      assert {:crash, :error, %RuntimeError{message: "odd"}, _} = outcome
      assert_raise RuntimeError, fn -> target.(input) end
    end
  end

  test "max_execs runs the target exactly that many times" do
    runs = :counters.new(1, [])
    target = fn _ -> :counters.add(runs, 1, 1) end

    stats = Runner.run(engine(1), target, report_to: self(), timeout: 1_000, max_execs: 1_000)

    assert :counters.get(runs, 1) == 1_000
    assert stats.engine.executions == 1_000
  end

  test "a solution on the last input is still reported" do
    Runner.run(engine(1), fn _ -> raise "last" end,
      report_to: self(),
      timeout: 1_000,
      max_execs: 1
    )

    assert_received {:ex_fuzz, :solution, %{outcome: {:crash, :error, %RuntimeError{}, _}}}
  end

  test "timeouts are solutions" do
    target = fn _ -> Process.sleep(:infinity) end
    Runner.run(engine(1), target, report_to: self(), timeout: 10, max_execs: 1)
    assert_received {:ex_fuzz, :solution, %{outcome: {:timeout, _}}}
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

  test ":stop ends the run, and every solution the engine counted is reported" do
    test = self()
    engine = engine(1)

    runner =
      spawn(fn ->
        stats = Runner.run(engine, fn _ -> raise "boom" end, report_to: test, timeout: 1_000)
        send(test, {:done, stats})
      end)

    assert_receive {:ex_fuzz, :solution, _}
    send(runner, :stop)
    assert_receive {:done, stats}

    assert length(solutions()) + 1 == stats.engine.solutions
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
