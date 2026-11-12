defmodule ExFuzz.Integration.CoordinatorTest do
  use ExUnit.Case, async: false

  # Each test fuzzes a fuzz test of the fixture file in a worker node.

  import ExFuzz.TestHelpers

  alias ExFuzz.{Coordinator, Fixtures}

  @fixture "test/support/fixtures/fuzz_test.exs"
  @opts [max_input_len: 64, rng_seed: 1]

  # The first line of the fixture that contains `code`.
  defp line(code) do
    @fixture
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, code))
    |> Kernel.+(1)
  end

  # The coordinator blocks, so it runs in a task and relays events to the test.
  defp coordinate(test, opts \\ []) do
    me = self()
    Task.async(fn -> Coordinator.run([report_to: me, test: test] ++ opts ++ @opts) end)
  end

  defp coordinate_at(code, opts \\ []), do: coordinate({@fixture, line(code)}, opts)

  defp await(task), do: Task.await(task, 30_000)

  test "fuzzes the fuzz target, which fails in ExUnit with the input" do
    original = SampleDep.Planted.module_info(:md5)

    {input, output} =
      with_node_io(fn ->
        task = coordinate_at(~s(fuzz "finds the planted bug"), max_time: 10_000)

        assert_receive {:ex_fuzz, :solution,
                        %{
                          input: "FUZZ" <> _ = input,
                          outcome: {:crash, :error, %RuntimeError{}, _}
                        }},
                       30_000

        assert {:done, %{engine: %{solutions: 1}}} = await(task)
        input
      end)

    assert output =~ "1) fuzz finds the planted bug (ExFuzz.Fixtures.FuzzTest)"
    assert output =~ ~r/\*\* \(ExFuzz.Error\) got RuntimeError \(planted\)\n\s+input: /
    assert output =~ "input: #{inspect(input)}\n"
    assert SampleDep.Planted.module_info(:md5) == original, "instrumented only in the worker node"
  end

  test "relays stats while fuzzing" do
    with_node_io(fn ->
      task =
        coordinate_at(~s(fuzz "never crashes"), max_time: 300, stats_interval: 50)

      assert_receive {:ex_fuzz, :started,
                      %{module: Fixtures.FuzzTest, test: :"fuzz never crashes"}},
                     30_000

      assert_receive {:ex_fuzz, :stats, %{engine: %{executions: _}}}, 30_000
      assert {:done, %{engine: %{solutions: 0}}} = await(task)
    end)
  end

  test ":stop sent to the coordinator stops fuzzing" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "never crashes"))

      assert_receive {:ex_fuzz, :stats, _}, 30_000
      send(task.pid, :stop)
      assert {:done, %{engine: %{solutions: 0}}} = await(task)
    end)
  end

  test ":stop before fuzzing starts stops the worker node" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "never crashes"))
      send(task.pid, :stop)
      assert await(task) == {:error, :stopped}
    end)
  end

  test "reports a fuzz test that calls nothing it can instrument" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "has nothing to instrument"))
      assert await(task) == {:error, :nothing_to_instrument}
    end)
  end

  test "selects the fuzz test by any line of it, as `mix test path:line` does" do
    with_node_io(fn ->
      line = line("SampleDep.Classifier.classify(data)")
      task = coordinate({@fixture, line}, max_execs: 100)
      assert {:done, %{engine: %{executions: 100}}} = await(task)
    end)
  end

  test "selects the fuzz test by its full name, as ExUnit prints it" do
    with_node_io(fn ->
      task = coordinate({@fixture, "fuzz in a describe never crashes either"}, max_execs: 100)

      assert {:done, %{engine: %{executions: 100}}} = await(task)
    end)
  end

  test "reports a run where no fuzz test fuzzed, with mix test's exit status" do
    {_result, output} =
      with_node_io(fn ->
        task = coordinate({@fixture, "no such test"})
        assert await(task) == {:not_started, {:exit_status, 1}}

        task = coordinate_at(~s(test "not a fuzz test"))
        assert await(task) == {:not_started, {:exit_status, 0}}
      end)

    assert output =~ "no test was executed"
  end

  test "passes :mix_args to the worker node's mix test" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "is slow"), mix_args: ["--timeout", "50"])

      assert_receive {:ex_fuzz, :solution, %{outcome: {:timeout, _}}}, 30_000
      assert {:done, %{engine: %{solutions: 1}}} = await(task)
    end)
  end

  test "a worker node that dies hard writes its crash dump under _build" do
    dump = "_build/ex_fuzz/erl_crash.dump"
    File.rm(dump)

    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "kills the VM with a crash dump"))
      assert {:node_down, {:exit_status, _}} = await(task)
    end)

    assert File.read!(dump) =~ "Slogan: fixture crash"
    refute File.exists?("erl_crash.dump")
  end

  test "reports a worker node whose VM dies" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "kills the VM"))
      assert {:node_down, {:exit_status, 7}} = await(task)
    end)
  end

  test "reports a worker node killed by a signal, as the OOM killer does: 128 + 9" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "is killed by a signal"))
      assert {:node_down, {:exit_status, 137}} = await(task)
    end)
  end
end
