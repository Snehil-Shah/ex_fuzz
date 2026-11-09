defmodule ExFuzz.WorkerTest do
  use ExUnit.Case, async: false

  import ExFuzz.TestHelpers

  alias ExFuzz.{Fixtures, Worker}

  @opts [max_input_len: 64, rng_seed: 1, seeds: ["AAAA"], timeout: 1_000]

  setup do
    # One worker per VM: let the previous test's worker exit before the next one registers.
    on_exit(fn ->
      if worker = Process.whereis(Worker) do
        ref = Process.monitor(worker)
        assert_receive {:DOWN, ^ref, _, _, _}, 1_000
      end
    end)
  end

  # Peer's mock I/O server, which delivers `{:message, to, msg}` to `to`.
  defp fake_group_leader do
    spawn_link(fn -> relay() end)
  end

  defp relay do
    receive do
      {:message, to, msg} -> send(to, msg)
    end

    relay()
  end

  defp start_worker(opts) do
    test = self()
    group_leader = fake_group_leader()

    spawn(fn ->
      Process.group_leader(self(), group_leader)
      send(test, {:started, Worker.start(test, opts)})
    end)

    assert_receive {:started, :ok}
  end

  test "fuzzes the target, pushes the solution, then :done" do
    restore_on_exit(Fixtures.Planted)

    start_worker(
      [target: {Fixtures.Planted, :check}, modules: [Fixtures.Planted], max_time: 5_000] ++ @opts
    )

    assert_receive {:ex_fuzz, :solution,
                    %{input: "FUZZ" <> _, outcome: {:crash, :error, %RuntimeError{}, _}}},
                   5_000

    assert_receive {:ex_fuzz, :done, %{engine: %{solutions: 1}}}
  end

  test "reports a setup failure" do
    start_worker([target: {ExFuzz.NoSuchModule, :f}, modules: [ExFuzz.NoSuchModule]] ++ @opts)
    assert_receive {:ex_fuzz, :error, {:no_object_code, ExFuzz.NoSuchModule}}
  end

  test ":stop sent to the registered name ends the run" do
    restore_on_exit(Fixtures.Classifier)

    start_worker(
      [target: {Fixtures.Classifier, :classify}, modules: [Fixtures.Classifier]] ++ @opts
    )

    send(Worker, :stop)
    assert_receive {:ex_fuzz, :done, %{engine: %{solutions: 0}}}
  end

  @tag :capture_log
  test "reports a worker that dies before finishing" do
    start_worker(target: {Fixtures.Classifier, :classify}, modules: [Fixtures.Classifier])
    restore_on_exit(Fixtures.Classifier)

    # No :max_input_len: setup raises inside the worker.
    assert_receive {:ex_fuzz, :error, {:worker_down, {%KeyError{key: :max_input_len}, _}}}
  end
end
