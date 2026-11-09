defmodule ExFuzz.Integration.CoordinatorTest do
  use ExUnit.Case, async: false

  # Each test starts a real worker.

  alias ExFuzz.{Coordinator, Fixtures}

  @opts [max_input_len: 64, rng_seed: 1, seeds: ["AAAA"], timeout: 1_000]

  # The coordinator blocks, so it runs in a task and relays events to the test.
  defp coordinate(opts) do
    test = self()
    Task.async(fn -> Coordinator.run([report_to: test] ++ opts ++ @opts) end)
  end

  test "finds a planted bug in the fuzz node and relays the solution" do
    original = Fixtures.Planted.module_info(:md5)

    task =
      coordinate(
        target: {Fixtures.Planted, :check},
        modules: [Fixtures.Planted],
        max_time: 10_000
      )

    assert_receive {:ex_fuzz, :solution,
                    %{input: "FUZZ" <> _, outcome: {:crash, :error, %RuntimeError{}, _}}},
                   10_000

    assert {:done, %{engine: %{solutions: 1}}} = Task.await(task)
    assert Fixtures.Planted.module_info(:md5) == original, "instrumented only in the fuzz node"
  end

  test "relays stats while fuzzing" do
    task =
      coordinate(
        target: {Fixtures.Classifier, :classify},
        modules: [Fixtures.Classifier],
        max_time: 300,
        stats_interval: 50
      )

    assert_receive {:ex_fuzz, :stats, %{engine: %{executions: _}}}, 5_000
    assert {:done, _stats} = Task.await(task)
  end

  test ":stop sent to the coordinator stops the worker" do
    task = coordinate(target: {Fixtures.Classifier, :classify}, modules: [Fixtures.Classifier])

    assert_receive {:ex_fuzz, :stats, _}, 5_000
    send(task.pid, :stop)
    assert {:done, %{engine: %{solutions: 0}}} = Task.await(task)
  end

  test "reports a setup failure" do
    task = coordinate(target: {ExFuzz.NoSuchModule, :f}, modules: [ExFuzz.NoSuchModule])
    assert {:error, {:no_object_code, ExFuzz.NoSuchModule}} = Task.await(task)
  end

  # `:peer` logs its control process exiting when the node dies.
  @tag :capture_log
  test "reports a fuzz node whose VM dies" do
    task = coordinate(target: {Fixtures.Halter, :halt}, modules: [Fixtures.Halter])
    assert {:node_down, {:exit_status, 7}} = Task.await(task)
  end
end
