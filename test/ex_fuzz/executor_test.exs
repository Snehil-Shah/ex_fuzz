defmodule ExFuzz.ExecutorTest do
  use ExUnit.Case, async: true

  alias ExFuzz.Executor

  defp run(target, input \\ "", opts \\ [timeout: 1_000]), do: Executor.run(target, input, opts)

  test "a normal return is :ok, whatever the target returns" do
    assert run(fn _ -> :anything end) == :ok
  end

  test "passes the input to the target" do
    test = self()
    run(fn input -> send(test, {:input, input}) end, "bytes")
    assert_received {:input, "bytes"}
  end

  test "every raise, throw and exit is a crash, as it would fail an ExUnit test" do
    assert {:crash, :error, %RuntimeError{message: "boom"}, [{__MODULE__, _, _, _} | _]} =
             run(fn _ -> raise "boom" end)

    assert {:crash, :throw, :ball, _} = run(fn _ -> throw(:ball) end)
    assert {:crash, :exit, :normal, _} = run(fn _ -> exit(:normal) end)

    assert {:crash, :error, %ExUnit.AssertionError{}, _} =
             run(fn input -> assert input == "x" end)
  end

  test "keeps the raw reason, normalized only when reported" do
    assert {:crash, :error, :badarg, _} = run(&String.to_integer/1, "not a number")
  end

  test "a linked process that kills the input is an {:EXIT, pid} crash" do
    assert {:crash, {:EXIT, pid}, :boom, []} =
             run(fn _ ->
               spawn_link(fn -> exit(:boom) end)
               Process.sleep(:infinity)
             end)

    assert is_pid(pid) and pid != self()
  end

  test "a timeout kills the input and reports where it was stuck" do
    assert {:timeout, stacktrace} =
             run(fn _ -> Process.sleep(:infinity) end, "", timeout: 10)

    assert Enum.any?(stacktrace, &match?({Process, :sleep, 1, _}, &1))
  end

  test "processes linked to the input die with it" do
    test = self()
    run(fn _ -> send(test, {:child, spawn_link(fn -> Process.sleep(:infinity) end)}) end)

    assert_received {:child, child}
    ref = Process.monitor(child)
    assert_receive {:DOWN, ^ref, :process, ^child, _}
  end

  test "leaves no messages in the caller's mailbox" do
    run(fn _ -> :ok end)
    run(fn _ -> raise "boom" end)
    run(fn _ -> Process.sleep(:infinity) end, "", timeout: 10)

    refute_receive _, 100
  end

  test "nothing leaks from one input to the next" do
    test = self()
    run(fn _ -> Process.put(:leftover, true) end)
    run(fn _ -> send(test, {:leftover, Process.get(:leftover)}) end)
    assert_received {:leftover, nil}
  end

  test "sets $callers to the calling process, as Task does" do
    test = self()
    run(fn _ -> send(test, {:callers, Process.get(:"$callers")}) end)
    assert_received {:callers, [^test]}
  end

  test "the input process starts with the configured heap" do
    test = self()
    heap = fn _ -> send(test, Process.info(self(), :min_heap_size)) end

    run(heap)
    assert_received {:min_heap_size, default}
    assert default >= 1_048_576

    run(heap, "", timeout: 1_000, min_heap_size: 4_096)
    assert_received {:min_heap_size, small}
    assert small >= 4_096 and small < default
  end
end
