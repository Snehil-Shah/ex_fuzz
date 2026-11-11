defmodule ExFuzz.InstrumentTest do
  use ExUnit.Case, async: false

  import ExFuzz.TestHelpers

  alias ExFuzz.{Engine, Fixtures, Instrument}

  # Instrument and load `modules` over a fresh engine.
  defp instrument!(modules) do
    {:ok, %{binaries: binaries, probes: probes}} = Instrument.instrument(modules)
    engine(map_len: probes)
    restore_on_exit(modules)
    :ok = Instrument.load(binaries)
    probes
  end

  # Ids of the probes that fired.
  defp hits(probes), do: for(id <- 0..(probes - 1), Engine.coverage_get(id) > 0, do: id)

  # Line where `Fixtures.Crasher.crash/0` raised, from its stack trace.
  defp crash_line do
    Fixtures.Crasher.crash()
  rescue
    _ ->
      [{Fixtures.Crasher, :crash, 0, location} | _] = __STACKTRACE__
      location[:line]
  end

  test "compiles modules into loadable binaries and counts their probes" do
    assert {:ok, %{binaries: [{Fixtures.Classifier, file, binary}], probes: 3}} =
             Instrument.instrument([Fixtures.Classifier])

    assert is_binary(binary)
    assert List.to_string(file) =~ "Elixir.ExFuzz.Fixtures.Classifier.beam"
  end

  test "loaded modules behave as before, and each branch fires its own probe" do
    probes = instrument!([Fixtures.Classifier])

    assert Fixtures.Classifier.classify(50) == :big
    big = hits(probes)
    engine(map_len: probes)
    assert Fixtures.Classifier.classify(1) == :small
    small = hits(probes)

    assert [entry, big_branch] = big
    assert [^entry, small_branch] = small
    assert big_branch != small_branch
  end

  test "every kind of clause fires its own probe" do
    probes = instrument!([Fixtures.Branches])

    # Probing must not change result.
    paths = [
      {fn -> Fixtures.Branches.head(1) end, :one},
      {fn -> Fixtures.Branches.head(2) end, :other},
      {fn -> Fixtures.Branches.anon(1) end, :one},
      {fn -> Fixtures.Branches.anon(2) end, :other},
      {fn -> Fixtures.Branches.recv({:ping, 1}) end, :pong},
      {fn -> Fixtures.Branches.recv(:other) end, :other},
      {fn -> Fixtures.Branches.rescued(:fine) end, :fine},
      {fn -> Fixtures.Branches.rescued(:boom) end, :rescued}
    ]

    hit_sets =
      for {path, result} <- paths do
        engine(map_len: probes)
        assert path.() == result
        hits(probes)
      end

    assert Enum.uniq(hit_sets) == hit_sets, "each path reaches a distinct set of probes"
  end

  test "numbers probes across modules without overlap" do
    {:ok, %{probes: classifier}} = Instrument.instrument([Fixtures.Classifier])
    {:ok, %{probes: shadow}} = Instrument.instrument([Fixtures.Shadow])
    total = instrument!([Fixtures.Classifier, Fixtures.Shadow])

    assert total == classifier + shadow

    Fixtures.Shadow.call(:anything)
    assert hits(total) != []
    assert Enum.all?(hits(total), &(&1 >= classifier)), "Shadow's probes come after Classifier's"
  end

  test "stack traces still point at the original source lines" do
    original = crash_line()
    instrument!([Fixtures.Crasher])
    assert crash_line() == original
  end

  test "leaves __info__/1 unprobed" do
    probes = instrument!([Fixtures.Classifier])
    Fixtures.Classifier.__info__(:functions)
    assert hits(probes) == []
  end

  test "a module shadowing an auto-imported BIF still calls its own function" do
    instrument!([Fixtures.Shadow])
    assert Fixtures.Shadow.call(:anything) == :mine
  end

  @tag :tmp_dir
  test "preserves compile options given outside the source, like export_all", %{tmp_dir: dir} do
    # `export_all` passed as a compiler option is recorded in the .beam, not in its abstract code.
    source = Path.join(dir, "instrument_export_all.erl")
    File.write!(source, "-module(instrument_export_all).\nhidden() -> secret.\n")

    {:ok, module, binary} =
      :compile.file(String.to_charlist(source), [:binary, :debug_info, :export_all])

    File.write!(Path.join(dir, "#{module}.beam"), binary)
    Code.prepend_path(dir)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      Code.delete_path(dir)
    end)

    {:ok, %{binaries: binaries, probes: probes}} = Instrument.instrument([module])
    engine(map_len: probes)
    :ok = Instrument.load(binaries)

    assert module.hidden() == :secret
  end

  test "fails for a module with no object code" do
    assert Instrument.instrument([ExFuzz.NoSuchModule]) ==
             {:error, {:no_object_code, ExFuzz.NoSuchModule}}
  end

  @tag :tmp_dir
  test "fails for a module compiled without debug info", %{tmp_dir: dir} do
    # `mix test` compiles with `debug_info: false`, so this module has no abstract code.
    [{module, binary}] =
      Code.compile_string("defmodule ExFuzz.InstrumentTest.NoDebug do\n def f, do: :ok\nend")

    File.write!(Path.join(dir, "#{module}.beam"), binary)
    Code.prepend_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)

    assert Instrument.instrument([module]) == {:error, {:no_debug_info, module}}
  end

  # The VM also logs the refusal.
  @tag :capture_log
  test "load reports a module the VM refuses to load" do
    compiled = [{Fixtures.Classifier, ~c"classifier.beam", "not a BEAM file"}]
    assert Instrument.load(compiled) == {:error, {Fixtures.Classifier, :badfile}}
  end
end
