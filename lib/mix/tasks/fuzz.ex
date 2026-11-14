defmodule Mix.Tasks.Fuzz do
  @shortdoc "Fuzzes one fuzz target"

  @moduledoc """
  Fuzzes one fuzz target, by the test's line or name:

      $ mix fuzz test/json_test.exs:6
      $ mix fuzz test/json_test.exs:"fuzz Jason never crashes"

  ## Options

    * `--max-time` - how long to fuzz, in milliseconds.
    * `--max-runs` - how many inputs to run.
    * `--timeout` - sets the timeout per input, in milliseconds.
    * `--trace` - fuzzes with detailed reporting, ignoring input timeouts.

  Without `--max-time` or `--max-runs`, fuzzing runs until an input fails the test.
  """

  use Mix.Task

  alias ExFuzz.Coordinator

  @switches [max_time: :integer, max_runs: :integer, timeout: :integer, trace: :boolean]
  @refresh_interval 3_000

  @impl Mix.Task
  def run(args) do
    {opts, argv} = OptionParser.parse!(args, strict: @switches)

    # ExUnit also does this for us. We still parse here to enforce a single fuzz target at a time.
    # TODO: This can be removed once we support parallel fuzzing with describe blocks.
    test = argv |> parse_test!() |> check_test!()

    [test: test, refresh_interval: @refresh_interval, mix_args: mix_args(opts)]
    |> Keyword.merge(budget(opts))
    |> fuzz()
    |> report()
  end

  defp parse_test!([test]) do
    case String.split(test, ".exs:", parts: 2) do
      [path, line_or_name] -> {path <> ".exs", line_or_name(line_or_name)}
      _ -> Mix.raise(~s(Expected a fuzz test as path:line or path:"fuzz name", got: #{test}))
    end
  end

  defp parse_test!(_argv) do
    Mix.raise(~s(Expected one fuzz test, as path:line or path:"fuzz name"))
  end

  defp line_or_name(line_or_name) do
    case Integer.parse(line_or_name) do
      {line, ""} -> line
      _ -> line_or_name
    end
  end

  # Only a single fuzz target can be fuzzed at a time.
  defp check_test!({path, line_or_name} = test) do
    source = read!(path)

    if is_integer(line_or_name) and not fuzz_target?(source, path, line_or_name) do
      Mix.raise("Line #{line_or_name} is not inside a fuzz test: give a line of one, or its name")
    end

    test
  end

  defp read!(path) do
    case File.read(path) do
      {:ok, source} -> source
      {:error, reason} -> Mix.raise("Could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp fuzz_target?(source, path, line) do
    {_ast, found?} =
      source
      |> Code.string_to_quoted!(file: path, token_metadata: true)
      |> Macro.prewalk(false, fn
        {:fuzz, meta, [_message | _]} = node, found? ->
          {node, found? or line in block_range(meta)}

        node, found? ->
          {node, found?}
      end)

    found?
  end

  # A call's lines: from its first to its `end`.
  defp block_range(meta) do
    last = get_in(meta, [:end, :line]) || get_in(meta, [:end_of_expression, :line]) || meta[:line]
    meta[:line]..last//1
  end

  defp budget(opts) do
    Enum.flat_map(opts, fn
      {:max_time, ms} -> [max_time: ms]
      {:max_runs, runs} -> [max_execs: runs]
      _ -> []
    end)
  end

  # Flags to forward to the child task.
  defp mix_args(opts) do
    Enum.flat_map(opts, fn
      {:timeout, timeout} -> ["--timeout", Integer.to_string(timeout)]
      {:trace, true} -> ["--trace"]
      _ -> []
    end)
  end

  defp fuzz(opts) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn -> exit({:done, Coordinator.run([report_to: parent] ++ opts)}) end)

    progress(pid, ref, nil)
  end

  defp progress(pid, ref, last) do
    receive do
      {:ex_fuzz, :stats, stats} ->
        Mix.shell().info(stats_line(stats, last))
        progress(pid, ref, stats)

      {:ex_fuzz, _started_or_solution, _} ->
        progress(pid, ref, last)

      {:DOWN, ^ref, :process, ^pid, {:done, {:done, stats} = result}} ->
        Mix.shell().info(stats_line(stats, last))
        result

      {:DOWN, ^ref, :process, ^pid, {:done, result}} ->
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  # Execs per second over the last interval.
  defp stats_line(%{engine: engine, elapsed_ms: elapsed}, last) do
    {last_execs, last_elapsed} =
      if last, do: {last.engine.executions, last.elapsed_ms}, else: {0, 0}

    rate = div((engine.executions - last_execs) * 1_000, max(elapsed - last_elapsed, 1))

    "fuzz: elapsed: #{seconds(elapsed)}, execs: #{engine.executions} (#{rate}/sec), " <>
      "corpus: #{engine.corpus}"
  end

  # Prints how the run ended.
  defp report({:done, %{engine: %{solutions: 0} = engine, elapsed_ms: elapsed}}) do
    Mix.shell().info("fuzz: no failures in #{engine.executions} execs, #{seconds(elapsed)}")
  end

  defp report({:done, %{engine: engine, elapsed_ms: elapsed}}) do
    Mix.shell().error(
      "fuzz: input failed the test after #{engine.executions} execs, #{seconds(elapsed)}"
    )

    exit({:shutdown, 1})
  end

  defp report({:not_started, reason}),
    do: Mix.raise("No fuzz target fuzzed (#{ending(reason)})")

  defp report({:node_down, reason}) do
    Mix.raise(
      "The worker node's VM died while fuzzing: #{ending(reason)}. " <>
        "Crash dump: #{Coordinator.crash_dump()}"
    )
  end

  defp report({:error, :nothing_to_instrument}) do
    Mix.raise(
      "Could not fuzz: nothing to instrument. " <>
        "Coverage is limited to your project and its dependencies"
    )
  end

  defp report({:error, reason}), do: Mix.raise("Could not fuzz: #{inspect(reason)}")

  # 128 + N: killed by signal N.
  defp ending({:exit_status, 137}), do: "signal 9, SIGKILL (the OOM killer sends it)"
  defp ending({:exit_status, 139}), do: "signal 11, SIGSEGV (a crashing NIF raises it)"
  defp ending({:exit_status, status}) when status > 128, do: "signal #{status - 128}"
  defp ending({:exit_status, status}), do: "exit status #{status}"
  defp ending(reason), do: inspect(reason)

  defp seconds(ms), do: "#{div(ms, 1_000)}s"
end
