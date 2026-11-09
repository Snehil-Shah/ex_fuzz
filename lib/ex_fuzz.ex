defmodule ExFuzz do
  @moduledoc """
  Coverage-guided fuzz testing for Elixir.

      defmodule MyParserTest do
        use ExUnit.Case
        use ExFuzz

        fuzz "parse never crashes", data <- binary(), seeds: ["{}", "[1]"] do
          MyParser.parse(data)
        end
      end

  Fuzz tests run alongside your regular ExUnit tests, using the seed corpus as the regression suite.
  """

  alias ExFuzz.Executor

  defmodule Error do
    @moduledoc "Raised when an input fails a fuzz test with anything but a failed assertion."
    defexception [:message]
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import ExFuzz, only: [fuzz: 3, fuzz: 4, fuzz: 5]
    end
  end

  @doc """
  Defines a fuzz test with `message`, running its body once per input.

  The test may also define a pattern, which will be matched against the test context.

  ## Options

    * `:seeds` - the seed corpus: example inputs that fuzzing starts from.

  ## Examples

      fuzz "parse never crashes", data <- binary(), seeds: ["{}", "[1]"] do
        MyParser.parse(data)
      end
  """
  defmacro fuzz(message, input, context \\ quote(do: _), opts \\ [], contents) do
    {context, opts} =
      if opts == [] and Keyword.keyword?(context),
        do: {quote(do: _), context},
        else: {context, opts}

    define(message, input, context, Keyword.validate!(opts, seeds: []), contents)
  end

  defp define(message, input, context, opts, do: block) do
    var = input!(input)
    full_context = Macro.var(:context, __MODULE__)
    ExUnit.plural_rule("fuzz", "fuzz")

    body =
      quote do
        # Not a tail call, so the test's own line stays in stack traces.
        ExFuzz.__replay__(unquote(opts[:seeds]), unquote(full_context), fn unquote(var) ->
          _ = unquote(block)
          :ok
        end)
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
  def __replay__(seeds, context, fun) do
    timeout = input_timeout(context[:input_timeout])

    for seed <- seeds do
      case Executor.run(fun, seed, timeout: timeout) do
        :ok ->
          :ok

        {:crash, kind, reason, stacktrace} ->
          fail(kind, reason, stacktrace, seed)

        {:timeout, stacktrace} ->
          fail("timed out after #{timeout} ms", stacktrace, seed)
      end
    end

    :ok
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

  @spec fail(term(), term(), Exception.stacktrace(), binary()) :: no_return()
  defp fail(:error, %ExUnit.AssertionError{} = error, stacktrace, seed) do
    reraise %{error | message: error.message <> "\nseed:  " <> inspect(seed)}, stacktrace
  end

  defp fail(kind, reason, stacktrace, seed) do
    {reason, stacktrace} = Exception.blame(kind, reason, stacktrace)
    fail(got(kind, reason), stacktrace, seed)
  end

  defp fail(message, stacktrace, seed) do
    reraise Error, [message: message <> "\nseed:  " <> inspect(seed)], stacktrace
  end

  defp got(:error, exception),
    do: "got #{inspect(exception.__struct__)} (#{Exception.message(exception)})"

  defp got({:EXIT, pid}, reason), do: "got exit from #{inspect(pid)} (#{inspect(reason)})"
  defp got(kind, reason), do: "got #{kind} #{inspect(reason)}"
end
