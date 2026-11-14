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

  test "saves an input to the corpus, by module and test, and loads it back", %{test: test} do
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
    assert Path.basename(path) == "c96c6d5be8d08a12"
    assert Corpus.load(__MODULE__, test) == [{path, "input"}]
  end

  test "loads inputs sorted by file name", %{test: test} do
    paths = for input <- ["a", "b", "c"], do: Corpus.save(__MODULE__, test, input)

    expected = for path <- Enum.sort(paths), do: {path, File.read!(path)}
    assert Corpus.load(__MODULE__, test) == expected
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
