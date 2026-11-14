defmodule ExFuzz do
  @moduledoc """
  Coverage-guided fuzz testing for Elixir.

      defmodule JasonTest do
        use ExUnit.Case
        use ExFuzz

        @tag timeout: 100
        fuzz "Jason never crashes", data <- binary(), seeds: ["{}", "[1]"] do
          with {:ok, term} <- Jason.decode(data) do
            assert Jason.decode!(Jason.encode!(term)) == term
          end
        end
      end

  Fuzz tests run alongside your regular ExUnit tests,
  using the seed corpus as an ever-growing regression suite.
  Run only them with `mix test --only fuzz`.

  To start fuzzing a target, point `mix fuzz` at the test by line or name:

      $ mix fuzz test/jason_test.exs:6
      $ mix fuzz test/jason_test.exs:"fuzz Jason never crashes"

  Failing inputs are saved as seed corpus to `test/fixtures/fuzz/` and replayed by `mix test` from then on.
  You can configure this with `:corpus_dir` under the `:ex_fuzz` key of your project config.
  """

  alias ExFuzz.{Corpus, Executor, Scope, Worker}

  # Worker environment settings. Defined by `ExFuzz.Coordinator` when dispatching fuzz workers.
  @worker_env "EX_FUZZ_WORKER"

  defmodule Error do
    @moduledoc "Raised when an input crashes or times out in a fuzz test."
    defexception [:message]
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ExFuzz, only: [fuzz: 3, fuzz: 4, fuzz: 5]
    end
  end

  @doc """
  Defines a fuzz test with `message`, running its body as the target, once per input.

  The test may also define a pattern, which will be matched against the test context.

  ## Options

    * `:seeds` - example inputs that fuzzing starts from, part of the seed corpus.

  ## Examples

      fuzz "Jason never crashes", data <- binary(), seeds: ["{}", "[1]"] do
        with {:ok, term} <- Jason.decode(data) do
          assert Jason.decode!(Jason.encode!(term)) == term
        end
      end

  You can start fuzzing the target using `mix fuzz`:

      $ mix fuzz test/jason_test.exs:"fuzz Jason never crashes"
  """
  defmacro fuzz(message, input, context \\ quote(do: _), opts \\ [], contents) do
    {context, opts} =
      if opts == [] and Keyword.keyword?(context),
        do: {quote(do: _), context},
        else: {context, opts}

    define(message, input, context, Keyword.validate!(opts, seeds: []), contents, __CALLER__)
  end

  defp define(message, input, context, opts, [do: block], env) do
    var = input!(input)
    # Instrumented along with the project.
    additional_modules = Scope.modules_called_by(block, env)
    full_context = Macro.var(:context, __MODULE__)
    ExUnit.plural_rule("fuzz", "fuzz")

    body =
      quote do
        # Not a tail call, so the test's own line stays in stack traces.
        ExFuzz.__run__(
          unquote(opts[:seeds]),
          unquote(additional_modules),
          unquote(full_context),
          fn unquote(var) ->
            _ = unquote(block)
            :ok
          end
        )
      end

    # Binds the user's pattern and the whole context, which carries `:input_timeout`.
    head = Macro.escape(quote(do: unquote(context) = unquote(full_context)))
    body = Macro.escape(body, unquote: true)

    quote bind_quoted: [message: message, head: head, body: body] do
      %{module: mod, file: file, line: line} = __ENV__
      # ExUnit's timeout applies to each input.
      tags = [:fuzz, timeout: :infinity, input_timeout: ExFuzz.__tag_timeout__(mod)]
      name = ExUnit.Case.register_test(mod, file, line, :fuzz, message, tags)
      def unquote(name)(unquote(head)), do: unquote(body)
    end
  end

  defp input!({:<-, _, [var, {:binary, _, []}]}), do: var

  defp input!(input) do
    raise ArgumentError,
          "expected a fuzz input like `data <- binary()`, got: #{Macro.to_string(input)}"
  end

  # ExUnit tag timeout precedence: @tag, then @describetag, then @moduletag.
  @doc false
  def __tag_timeout__(mod) do
    [:tag, :describetag, :moduletag]
    |> Enum.flat_map(&(Module.get_attribute(mod, &1) || []))
    |> Enum.find_value(fn
      {:timeout, timeout} -> timeout
      tags when is_list(tags) -> Keyword.get(tags, :timeout)
      _tag -> nil
    end)
  end

  @doc false
  def __run__(seeds, additional_modules, context, fun) do
    timeout = input_timeout(context[:input_timeout])

    # If worker environment is defined, start the worker loop.
    case System.get_env(@worker_env) do
      nil ->
        replay(seeds, context, timeout, fun)

      settings ->
        run_fuzzer(settings, context, seeds, additional_modules, timeout, fun)
    end
  end

  defp replay(seeds, context, timeout, fun) do
    corpus = Corpus.load(context.module, context.test)

    inputs =
      Enum.map(seeds, &{&1, "seed:  " <> inspect(&1)}) ++
        for {path, input} <- corpus, do: {input, "seed:  #{inspect(input)}\nfile:  #{path}"}

    for {input, label} <- inputs do
      case Executor.run(fun, input, timeout: timeout) do
        :ok -> :ok
        failure -> fail(failure, timeout, label)
      end
    end

    :ok
  end

  defp run_fuzzer(settings, context, seeds, additional_modules, timeout, fun) do
    case Worker.run(settings, context, seeds, additional_modules, timeout, fun) do
      :ok ->
        :ok

      {:solution, %{input: input, outcome: failure}, path} ->
        rerun = "mix test #{Path.relative_to_cwd(context.file)}:#{context.line}"
        fail(failure, timeout, "input: #{inspect(input)}\nfile:  #{path}\nrerun: #{rerun}")

      {:error, reason} ->
        raise Error, "could not start fuzzing: #{inspect(reason)}"
    end
  end

  # ExUnit timeout precedence: --trace disables it, then the tag, then the config.
  defp input_timeout(tag_timeout) do
    config = ExUnit.configuration()

    cond do
      config[:trace] -> :infinity
      tag_timeout -> tag_timeout
      true -> config[:timeout]
    end
  end

  @spec fail(Executor.outcome(), timeout(), String.t()) :: no_return()
  defp fail({:crash, :error, %ExUnit.AssertionError{} = error, stacktrace}, _timeout, input) do
    reraise %{error | message: error.message <> "\n" <> input}, stacktrace
  end

  defp fail({:crash, kind, reason, stacktrace}, _timeout, input) do
    {reason, stacktrace} = Exception.blame(kind, reason, stacktrace)
    raise_error(got(kind, reason), stacktrace, input)
  end

  defp fail({:timeout, stacktrace}, timeout, input) do
    raise_error("timed out after #{timeout} ms", stacktrace, input)
  end

  defp raise_error(message, stacktrace, input) do
    reraise Error, [message: message <> "\n" <> input], stacktrace
  end

  defp got(:error, exception),
    do: "got #{inspect(exception.__struct__)} (#{Exception.message(exception)})"

  defp got({:EXIT, pid}, reason), do: "got exit from #{inspect(pid)} (#{inspect(reason)})"
  defp got(kind, reason), do: "got #{kind} #{inspect(reason)}"
end
