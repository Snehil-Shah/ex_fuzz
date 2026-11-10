defmodule ExFuzz.WorkerTest do
  use ExUnit.Case, async: false

  import ExFuzz.TestHelpers

  alias ExFuzz.{Fixtures, Worker}

  defp settings(overrides) do
    Keyword.merge(
      [
        origin: self(),
        io: self(),
        test: {"test.exs", 1},
        modules: [],
        max_input_len: 64,
        rng_seed: 1
      ],
      overrides
    )
  end

  @context %{module: SomeTest, test: :"fuzz something", describe_line: nil}

  # Settings arrive encoded, as the coordinator hands them over.
  defp run(settings, target, context \\ @context),
    do: Worker.run(Worker.encode(settings), context, ["AAAA"], 1_000, target)

  test "fuzzes the target, then pushes the solution and :done, in order" do
    restore_on_exit(Fixtures.Planted)
    settings = settings(modules: [Fixtures.Planted], max_time: 5_000)

    assert {:solution, %{input: "FUZZ" <> _, outcome: {:crash, :error, %RuntimeError{}, _}}} =
             run(settings, &Fixtures.Planted.check/1)

    origin = self()
    started = %{module: SomeTest, test: :"fuzz something"}
    assert_receive {:message, ^origin, {:ex_fuzz, :started, ^started}}
    assert_receive {:message, ^origin, {:ex_fuzz, :solution, %{input: "FUZZ" <> _}}}
    assert_receive {:message, ^origin, {:ex_fuzz, :done, %{engine: %{solutions: 1}}}}
  end

  test "pushes stats while fuzzing, and :done when a budget is spent" do
    restore_on_exit(Fixtures.Classifier)
    settings = settings(modules: [Fixtures.Classifier], max_time: 200, stats_interval: 20)

    assert run(settings, &Fixtures.Classifier.classify/1) == :ok
    assert_receive {:message, _, {:ex_fuzz, :stats, %{engine: %{executions: _}}}}
    assert_receive {:message, _, {:ex_fuzz, :done, %{engine: %{solutions: 0}}}}
  end

  test "stop/0 ends the run" do
    restore_on_exit(Fixtures.Classifier)
    settings = settings(modules: [Fixtures.Classifier], stats_interval: 20)
    worker = Task.async(fn -> run(settings, &Fixtures.Classifier.classify/1) end)

    assert_receive {:message, _, {:ex_fuzz, :stats, _}}
    assert Worker.stop() == :ok
    assert Task.await(worker) == :ok
    assert_receive {:message, _, {:ex_fuzz, :done, %{engine: %{solutions: 0}}}}
  end

  test "reports a setup failure" do
    assert run(settings(modules: [ExFuzz.NoSuchModule]), & &1) ==
             {:error, {:no_object_code, ExFuzz.NoSuchModule}}

    assert_receive {:message, _, {:ex_fuzz, :error, {:no_object_code, ExFuzz.NoSuchModule}}}
  end

  test "refuses to fuzz when the line selects a whole describe block" do
    settings = settings(test: {"test.exs", 5}, modules: [Fixtures.Classifier])

    assert run(settings, &Fixtures.Classifier.classify/1, %{@context | describe_line: 5}) ==
             {:error, {:describe_line, 5}}

    assert_receive {:message, _, {:ex_fuzz, :error, {:describe_line, 5}}}
  end

  test "frees the registered name when it returns" do
    run(settings(modules: [ExFuzz.NoSuchModule]), & &1)
    assert Process.whereis(Worker) == nil
  end
end
