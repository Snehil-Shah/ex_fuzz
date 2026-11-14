defmodule ExFuzzTest do
  use ExUnit.Case, async: true
  use ExFuzz

  defmodule Examples do
    use ExUnit.Case, register: false
    use ExFuzz

    # ExUnit's timeout tags, applied per input.
    @moduletag timeout: 30

    @tag timeout: 10
    fuzz "hangs with a test tag", _data <- binary(), seeds: ["x"] do
      Process.sleep(:infinity)
    end

    fuzz "hangs with the module tag", _data <- binary(), seeds: ["x"] do
      Process.sleep(:infinity)
    end

    describe "inside describe" do
      @describetag timeout: 20
      fuzz "hangs", _data <- binary(), seeds: ["x"] do
        Process.sleep(:infinity)
      end
    end

    fuzz "replays", data <- binary(), %{to: to}, seeds: ["a", "b"] do
      send(to, {:ran, data, self(), Process.get(:"$callers")})
    end

    fuzz "uses the context", data <- binary(), %{to: to}, seeds: ["x"] do
      send(to, {:context, data})
    end

    fuzz "fails an assertion", data <- binary(), seeds: ["ok", "bad"] do
      assert data == "ok"
    end

    fuzz "raises", data <- binary(), seeds: ["boom"] do
      raise ArgumentError, "bad #{data}"
    end

    fuzz "throws", data <- binary(), seeds: ["x"] do
      throw({:ball, data})
    end

    fuzz "is killed by a linked process", _data <- binary(), seeds: ["x"] do
      spawn_link(fn -> exit(:boom) end)
      Process.sleep(:infinity)
    end

    fuzz "fails in a call", data <- binary(), seeds: ["not a number"] do
      String.to_integer(data)
    end

    fuzz "fails only on a saved input", data <- binary(), seeds: ["ok"] do
      if data == "FAIL", do: raise("found")
    end
  end

  import ExFuzz.TestHelpers

  alias ExFuzz.Corpus

  # Calls an example as ExUnit would.
  defp run(name, context \\ %{}) do
    %{tags: tags} = Enum.find(Examples.__ex_unit__().tests, &(&1.name == name))
    apply(Examples, name, [Map.merge(tags, Map.merge(%{module: Examples, test: name}, context))])
  end

  # A real fuzz test, run by this suite.
  fuzz "runs under mix test like any test", data <- binary(), seeds: ["a"] do
    assert data == "a"
  end

  test "registers an ExUnit test of type :fuzz, tagged :fuzz" do
    assert %{tags: %{test_type: :fuzz, fuzz: true, timeout: :infinity}} =
             Enum.find(Examples.__ex_unit__().tests, &(&1.name == :"fuzz replays"))
  end

  test "runs the body once per seed, each in a fresh process with $callers set" do
    test = self()
    run(:"fuzz replays", %{to: test})

    assert_received {:ran, "a", pid_a, [^test]}
    assert_received {:ran, "b", pid_b, [^test]}
    assert pid_a != test and pid_b != test and pid_a != pid_b
  end

  test "binds the test context, like test/3" do
    run(:"fuzz uses the context", %{to: self()})
    assert_received {:context, "x"}
  end

  test "a failed assertion stays an assertion, with the input in front" do
    error = assert_raise ExUnit.AssertionError, fn -> run(:"fuzz fails an assertion") end
    assert error.message == ~s(Assertion with == failed\nseed:  "bad")
    assert {error.left, error.right} == {"bad", "ok"}
  end

  test "any other failure becomes ExFuzz.Error, with the input and the original exception" do
    error = assert_raise ExFuzz.Error, fn -> run(:"fuzz raises") end
    assert error.message == ~s[got ArgumentError (bad boom)\nseed:  "boom"]
  end

  test "an input killed by a linked process is reported as an exit" do
    error =
      assert_raise ExFuzz.Error, fn -> run(:"fuzz is killed by a linked process") end

    assert error.message =~ ~r/\Agot exit from #PID<[\d.]+> \(:boom\)\nseed:  "x"\z/
  end

  test "ExUnit's timeout applies to each input, with ExUnit's tag precedence" do
    for {test, timeout} <- [
          "fuzz hangs with a test tag": 10,
          "fuzz inside describe hangs": 20,
          "fuzz hangs with the module tag": 30
        ] do
      error = assert_raise ExFuzz.Error, fn -> run(test) end
      assert error.message == ~s(timed out after #{timeout} ms\nseed:  "x")
    end
  end

  test "a throw or an exit is reported by kind" do
    error = assert_raise ExFuzz.Error, fn -> run(:"fuzz throws") end
    assert error.message == ~s[got throw {:ball, "x"}\nseed:  "x"]
  end

  test "the failing line of the fuzz body stays in the stack trace" do
    run(:"fuzz fails in a call")
  rescue
    ExFuzz.Error ->
      # The body is an anonymous function inside the generated test function.
      assert Enum.any?(__STACKTRACE__, fn {module, function, _, _} ->
               module == Examples and
                 Atom.to_string(function) =~ ~r/^-fuzz fails in a call\/1-fun-/
             end)
  end

  test "only `name <- binary()` inputs compile, for now" do
    assert_raise ArgumentError, ~r/expected a fuzz input like `data <- binary\(\)`/, fn ->
      Code.compile_string("""
      defmodule ExFuzzTest.BadInput do
        use ExUnit.Case, register: false
        use ExFuzz
        fuzz "x", n <- integer(), do: n
      end
      """)
    end
  end

  test "replays the test's corpus after its seeds" do
    on_exit(fn -> clear_corpus(Examples) end)
    run(:"fuzz fails only on a saved input")

    path = Corpus.save(Examples, :"fuzz fails only on a saved input", "FAIL")
    error = assert_raise ExFuzz.Error, fn -> run(:"fuzz fails only on a saved input") end
    assert error.message == ~s|got RuntimeError (found)\nseed:  "FAIL"\nfile:  #{path}|
  end
end
