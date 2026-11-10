defmodule ExFuzz.Integration.CoordinatorTest do
  use ExUnit.Case, async: false

  # Each test fuzzes a fuzz test of the fixture file in a worker node.

  # `:peer` logs its control process exiting whenever the node ends.
  @moduletag :capture_log

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
  defp coordinate(test, opts) do
    me = self()
    Task.async(fn -> Coordinator.run([report_to: me, test: test] ++ opts ++ @opts) end)
  end

  defp coordinate_at(code, opts), do: coordinate({@fixture, line(code)}, opts)

  defp await(task), do: Task.await(task, 30_000)

  test "fuzzes the fuzz target, which fails in ExUnit with the input" do
    original = Fixtures.Planted.module_info(:md5)

    {input, output} =
      with_node_io(fn ->
        task =
          coordinate_at(~s(fuzz "finds the planted bug"),
            modules: [Fixtures.Planted],
            max_time: 10_000
          )

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
    assert Fixtures.Planted.module_info(:md5) == original, "instrumented only in the worker node"
  end

  test "relays stats while fuzzing" do
    with_node_io(fn ->
      task =
        coordinate_at(~s(fuzz "never crashes"),
          modules: [Fixtures.Classifier],
          max_time: 300,
          stats_interval: 50
        )

      assert_receive {:ex_fuzz, :started,
                      %{module: Fixtures.FuzzTest, test: :"fuzz never crashes"}},
                     30_000

      assert_receive {:ex_fuzz, :stats, %{engine: %{executions: _}}}, 30_000
      assert {:done, %{engine: %{solutions: 0}}} = await(task)
    end)
  end

  test ":stop sent to the coordinator stops fuzzing" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "never crashes"), modules: [Fixtures.Classifier])

      assert_receive {:ex_fuzz, :stats, _}, 30_000
      send(task.pid, :stop)
      assert {:done, %{engine: %{solutions: 0}}} = await(task)
    end)
  end

  test ":stop before fuzzing starts stops the worker node" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "never crashes"), modules: [Fixtures.Classifier])
      send(task.pid, :stop)
      assert await(task) == {:error, :stopped}
    end)
  end

  test "reports a setup failure" do
    with_node_io(fn ->
      # The fixture's own module: `mix test` compiles it in memory, so it has no object code.
      task = coordinate_at(~s(fuzz "never crashes"), modules: [Fixtures.FuzzTest])
      assert {:error, {:no_object_code, Fixtures.FuzzTest}} = await(task)
    end)
  end

  test "selects the fuzz test by any line of it, as `mix test path:line` does" do
    with_node_io(fn ->
      line = line("Fixtures.Classifier.classify(data)")
      task = coordinate({@fixture, line}, modules: [Fixtures.Classifier], max_execs: 100)
      assert {:done, %{engine: %{executions: 100}}} = await(task)
    end)
  end

  test "selects the fuzz test by its full name, as ExUnit prints it" do
    with_node_io(fn ->
      task =
        coordinate({@fixture, "fuzz in a describe never crashes either"},
          modules: [Fixtures.Classifier],
          max_execs: 100
        )

      assert {:done, %{engine: %{executions: 100}}} = await(task)
    end)
  end

  test "refuses a describe line, which selects every test in the block" do
    with_node_io(fn ->
      line = line(~s(describe "in a describe"))
      task = coordinate_at(~s(describe "in a describe"), modules: [Fixtures.Classifier])
      assert await(task) == {:error, {:describe_line, line}}
    end)
  end

  test "reports a run where no fuzz test fuzzed, with mix test's exit status" do
    {_result, output} =
      with_node_io(fn ->
        task = coordinate({@fixture, "no such test"}, modules: [Fixtures.Classifier])
        assert await(task) == {:not_started, {:exit_status, 1}}

        task = coordinate_at(~s(test "not a fuzz test"), modules: [Fixtures.Classifier])
        assert await(task) == {:not_started, {:exit_status, 0}}
      end)

    assert output =~ "no test was executed"
  end

  test "a worker node that dies hard writes its crash dump under _build" do
    dump = "_build/ex_fuzz/erl_crash.dump"
    File.rm(dump)

    with_node_io(fn ->
      task =
        coordinate_at(~s(fuzz "kills the VM with a crash dump"), modules: [Fixtures.Halter])

      assert {:node_down, {:exit_status, _}} = await(task)
    end)

    assert File.read!(dump) =~ "Slogan: fixture crash"
    refute File.exists?("erl_crash.dump")
  end

  test "reports a worker node whose VM dies" do
    with_node_io(fn ->
      task = coordinate_at(~s(fuzz "kills the VM"), modules: [Fixtures.Halter])
      assert {:node_down, {:exit_status, 7}} = await(task)
    end)
  end
end
