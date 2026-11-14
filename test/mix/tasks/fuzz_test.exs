defmodule Mix.Tasks.FuzzTest do
  use ExUnit.Case, async: false

  import ExFuzz.TestHelpers

  alias Mix.Tasks.Fuzz

  @fixture "test/fixtures/fuzz_fixture.exs"

  setup do
    clear_corpus(ExFuzz.Fixtures.FuzzTest)
    on_exit(fn -> clear_corpus(ExFuzz.Fixtures.FuzzTest) end)
  end

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  # The first line of the fixture that contains `code`.
  defp line(code) do
    @fixture
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, code))
    |> Kernel.+(1)
  end

  test "fuzzes a test by any line of it, within --max-runs" do
    # Any line to the test body selects it.
    line = line(~s(fuzz "never crashes")) + 1

    with_node_io(fn ->
      Fuzz.run(["#{@fixture}:#{line}", "--max-runs", "100"])
    end)

    assert_received {:mix_shell, :info, ["fuzz: elapsed: " <> _ = line]}
    assert line =~ ~r/execs: 100 \(\d+\/sec\), corpus: \d+$/
    assert_received {:mix_shell, :info, ["fuzz: no failures in 100 execs, " <> _]}
  end

  test "fuzzes a test by its name, within --max-time" do
    with_node_io(fn ->
      Fuzz.run(["#{@fixture}:fuzz never crashes", "--max-time", "500"])
    end)

    assert_received {:mix_shell, :info, ["fuzz: no failures in " <> summary]}
    assert summary =~ ~r/ execs, 0s$/
  end

  test "a failing input fails the test in ExUnit's report" do
    {exit, output} =
      with_node_io(fn ->
        catch_exit(Fuzz.run(["#{@fixture}:fuzz finds the planted bug", "--max-time", "10000"]))
      end)

    assert exit == {:shutdown, 1}
    assert_received {:mix_shell, :error, ["fuzz: input failed the test after " <> _]}
    assert output =~ ~r/got RuntimeError \(planted\)\n\s+input: /
  end

  test "wants exactly one fuzz test" do
    assert_raise Mix.Error, ~r/Expected one fuzz test/, fn -> Fuzz.run([]) end
    assert_raise Mix.Error, ~r/Expected a fuzz test/, fn -> Fuzz.run(["test/a.exs"]) end
  end

  test "passes --timeout to the worker node, and exits 1 on a failing input" do
    with_node_io(fn ->
      assert catch_exit(Fuzz.run(["#{@fixture}:fuzz is slow", "--timeout", "50"])) ==
               {:shutdown, 1}
    end)

    assert_received {:mix_shell, :error, ["fuzz: input failed the test after " <> _]}
  end

  test "a fuzz test that calls nothing fails" do
    with_node_io(fn ->
      assert_raise Mix.Error,
                   ~r/nothing to instrument. Coverage is limited to your project and its dependencies/,
                   fn ->
                     Fuzz.run(["#{@fixture}:fuzz has nothing to instrument"])
                   end
    end)
  end

  test "refuses a missing file" do
    for test <- ["test/missing_test.exs:3", "test/missing_test.exs:fuzz anything"] do
      assert_raise Mix.Error,
                   "Could not read test/missing_test.exs: no such file or directory",
                   fn -> Fuzz.run([test]) end
    end
  end

  @tag :tmp_dir
  test "refuses a file that doesn't parse", %{tmp_dir: dir} do
    path = Path.join(dir, "broken_test.exs")
    File.write!(path, ~s(defmodule BrokenTest do\n  test "x" do\n))

    error = assert_raise TokenMissingError, fn -> Fuzz.run(["#{path}:2"]) end
    assert Exception.message(error) =~ "missing terminator: end"
  end

  test "refuses a line outside every fuzz test" do
    lines = [
      # Above the first test.
      1,
      # A describe block, which selects every test in it.
      line(~s(describe "in a describe")),
      # A regular test.
      line(~s(test "not a fuzz test")),
      # Past the end of the file.
      9_999
    ]

    for line <- lines do
      assert_raise Mix.Error,
                   "Line #{line} is not inside a fuzz test: give a line of one, or its name",
                   fn ->
                     Fuzz.run(["#{@fixture}:#{line}", "--max-runs", "1"])
                   end
    end
  end

  test "a run where no fuzz test fuzzed fails" do
    with_node_io(fn ->
      assert_raise Mix.Error, ~r/No fuzz target fuzzed \(exit status 1\)/, fn ->
        Fuzz.run(["#{@fixture}:fuzz no such test"])
      end
    end)
  end

  test "a worker node killed by a signal is reported" do
    error =
      with_node_io(fn ->
        assert_raise Mix.Error, fn -> Fuzz.run(["#{@fixture}:fuzz is killed by a signal"]) end
      end)
      |> elem(0)

    assert error.message =~ "signal 9, SIGKILL (the OOM killer sends it)"
    assert error.message =~ "Crash dump: #{ExFuzz.Coordinator.crash_dump()}"
  end
end
