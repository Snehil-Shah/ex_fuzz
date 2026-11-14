defmodule ExFuzz.CorpusTest do
  use ExUnit.Case, async: true

  alias ExFuzz.{Config, Corpus}

  # Clear test artifacts.
  setup %{test: test} do
    on_exit(fn ->
      for key <- [:corpus_dir, :cache_dir] do
        File.rm_rf!(Path.join([Config.get(key), inspect(__MODULE__), name(test)]))
      end
    end)
  end

  defp name(test), do: test |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9]+/, "_")

  test "saves an input to the corpus", %{test: test} do
    path = Corpus.save(__MODULE__, test, "input")

    assert Path.dirname(path) ==
             Path.join([Config.get(:corpus_dir), "ExFuzz.CorpusTest", name(test)])

    assert Corpus.load(__MODULE__, test) == [{path, "input"}]
  end

  test "names a test's directory after its name" do
    path = Corpus.save(__MODULE__, :"fuzz in a describe parses JSON!", "input")
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    assert path |> Path.dirname() |> Path.basename() == "in_a_describe_parses_JSON"
  end

  test "names an input by its content, so saving it twice keeps one file", %{test: test} do
    path = Corpus.save(__MODULE__, test, "input")
    assert Corpus.save(__MODULE__, test, "input") == path
    assert Path.basename(path) == "c1c994cd36f0dbfb"
    assert Corpus.load(__MODULE__, test) == [{path, "input"}]
  end

  test "writes an input as a version line and an escaped string literal", %{test: test} do
    input = ~S(a"\#{x}) <> "\n\r\t" <> <<0, 194, 150, 255>>
    path = Corpus.save(__MODULE__, test, input)

    assert File.read!(path) == ~S(ex_fuzz v1
"a\"\\\#{x}\n\r\t\x00\xC2\x96\xFF"
)

    assert Corpus.load(__MODULE__, test) == [{path, input}]
  end

  test "reads files with Windows line endings", %{test: test} do
    path = Corpus.save(__MODULE__, test, "input")
    File.write!(path, String.replace(File.read!(path), "\n", "\r\n"))
    assert Corpus.load(__MODULE__, test) == [{path, "input"}]
  end

  test "refuses loading a file with broken encoding", %{test: test} do
    path = Corpus.save(__MODULE__, test, "input")

    for contents <- ["input", ~s(ex_fuzz v2\n"input"\n), ~s(ex_fuzz v1\n:input\n)] do
      File.write!(path, contents)
      message = "invalid corpus file: #{path}"
      assert_raise RuntimeError, message, fn -> Corpus.load(__MODULE__, test) end
    end
  end

  test "loads inputs sorted by file name", %{test: test} do
    saved = for input <- ["a", "b", "c"], do: {Corpus.save(__MODULE__, test, input), input}
    assert Corpus.load(__MODULE__, test) == Enum.sort(saved)
  end

  test "loads nothing for a test with no saved inputs", %{test: test} do
    assert Corpus.load(__MODULE__, test) == []
    assert Corpus.load_cache(__MODULE__, test) == []
  end

  test "keeps the corpus and the cache apart", %{test: test} do
    found = Corpus.save(__MODULE__, test, "found")
    path = Corpus.save_cache(__MODULE__, test, "generated")

    assert Path.dirname(path) ==
             Path.join([Config.get(:cache_dir), "ExFuzz.CorpusTest", name(test)])

    assert Corpus.load(__MODULE__, test) == [{found, "found"}]
    assert Corpus.load_cache(__MODULE__, test) == [{path, "generated"}]
  end
end
