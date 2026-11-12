defmodule ExFuzz.WorkerTest do
  use ExUnit.Case, async: false

  import ExFuzz.TestHelpers

  alias ExFuzz.Worker

  defp settings(overrides) do
    Keyword.merge(
      [
        origin: self(),
        io: self(),
        max_input_len: 64,
        rng_seed: 1
      ],
      overrides
    )
  end

  @context %{module: SomeTest, test: :"fuzz something"}

  # Settings arrive encoded, as the coordinator hands them over.
  defp run(settings, target, additional_modules),
    do:
      Worker.run(
        Worker.encode_settings(settings),
        @context,
        ["AAAA"],
        additional_modules,
        1_000,
        target
      )

  test "fuzzes the target, then pushes the solution and :done, in order" do
    restore_on_exit(SampleDep.Planted)
    settings = settings(max_time: 5_000)

    assert {:solution, %{input: "FUZZ" <> _, outcome: {:crash, :error, %RuntimeError{}, _}}} =
             run(settings, &SampleDep.Planted.check/1, [SampleDep.Planted])

    origin = self()
    started = %{module: SomeTest, test: :"fuzz something"}
    assert_receive {:message, ^origin, {:ex_fuzz, :started, ^started}}
    assert_receive {:message, ^origin, {:ex_fuzz, :solution, %{input: "FUZZ" <> _}}}
    assert_receive {:message, ^origin, {:ex_fuzz, :done, %{engine: %{solutions: 1}}}}
  end

  test "pushes stats while fuzzing, and :done when a budget is spent" do
    restore_on_exit(SampleDep.Classifier)
    settings = settings(max_time: 200, stats_interval: 20)

    assert run(settings, &SampleDep.Classifier.classify/1, [SampleDep.Classifier]) == :ok
    assert_receive {:message, _, {:ex_fuzz, :stats, %{engine: %{executions: _}}}}
    assert_receive {:message, _, {:ex_fuzz, :done, %{engine: %{solutions: 0}}}}
  end

  test "stop/0 ends the run" do
    restore_on_exit(SampleDep.Classifier)
    settings = settings(stats_interval: 20)

    worker =
      Task.async(fn ->
        run(settings, &SampleDep.Classifier.classify/1, [SampleDep.Classifier])
      end)

    assert_receive {:message, _, {:ex_fuzz, :stats, _}}
    assert Worker.stop() == :ok
    assert Task.await(worker) == :ok
    assert_receive {:message, _, {:ex_fuzz, :done, %{engine: %{solutions: 0}}}}
  end

  test "reports a fuzz test that calls nothing it can instrument" do
    assert run(settings([]), & &1, [Enum]) == {:error, :nothing_to_instrument}
    assert_receive {:message, _, {:ex_fuzz, :error, :nothing_to_instrument}}
  end

  test "frees the registered name when it returns" do
    run(settings([]), & &1, [])
    assert Process.whereis(Worker) == nil
  end
end
