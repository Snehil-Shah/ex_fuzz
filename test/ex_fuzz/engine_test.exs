defmodule ExFuzz.EngineTest do
  use ExUnit.Case, async: false

  alias ExFuzz.Engine

  # Crashes only on inputs starting with "FUZZ".
  defmodule PlantedBug do
    alias ExFuzz.Engine

    def parse(<<?F, rest::binary>>) do
      Engine.hit(1)
      s1(rest)
    end

    def parse(_) do
      Engine.hit(0)
      :ok
    end

    defp s1(<<?U, rest::binary>>) do
      Engine.hit(2)
      s2(rest)
    end

    defp s1(_), do: :ok

    defp s2(<<?Z, rest::binary>>) do
      Engine.hit(3)
      s3(rest)
    end

    defp s2(_), do: :ok

    defp s3(<<?Z, _::binary>>) do
      Engine.hit(4)
      raise "planted bug"
    end

    defp s3(_), do: :ok
  end

  defp opts(overrides \\ %{}) do
    Map.merge(%{map_len: 8, max_input_len: 4096, rng_seed: 42, seeds: ["AAAA"]}, overrides)
  end

  # The caller-owned fuzz loop. Returns the input that triggered the
  # objective, or nil once the budget is spent.
  defp fuzz(_engine, _target, 0), do: nil

  defp fuzz(engine, target, budget) do
    input = Engine.next(engine)

    outcome =
      try do
        target.(input)
        :ok
      rescue
        _ -> :crash
      end

    case Engine.report(engine, outcome) do
      :solution -> input
      _verdict -> fuzz(engine, target, budget - 1)
    end
  end

  test "probes write into the coverage map and next resets it" do
    {:ok, engine} = Engine.new(opts())
    Engine.hit(5)
    Engine.hit(5)
    assert Engine.coverage_get(5) == 2
    Engine.next(engine)
    assert Engine.coverage_get(5) == 0
  end

  test "finds a bug behind a 4-byte magic prefix using coverage feedback" do
    {:ok, engine} = Engine.new(opts())
    found = fuzz(engine, &PlantedBug.parse/1, 2_000_000)

    assert is_binary(found), "planted bug not found within budget"
    assert String.starts_with?(found, "FUZZ")
    assert %{solutions: 1, executions: executions, corpus: corpus} = Engine.stats(engine)
    assert executions > 0
    assert corpus > 1
  end

  test "reports new coverage as a :corpus verdict" do
    {:ok, engine} = Engine.new(opts())
    Engine.next(engine)
    Engine.hit(0)
    assert Engine.report(engine, :ok) == :corpus
    Engine.next(engine)
    Engine.hit(0)
    assert Engine.report(engine, :ok) == :none
  end

  test "reports crashes and timeouts as :solution verdicts" do
    {:ok, engine} = Engine.new(opts())
    Engine.next(engine)
    assert Engine.report(engine, :crash) == :solution
    Engine.next(engine)
    assert Engine.report(engine, :timeout) == :solution
    assert %{solutions: 2} = Engine.stats(engine)
  end

  test "rejects invalid options with an error tuple" do
    assert {:error, message} = Engine.new(opts(%{map_len: 0}))
    assert message =~ "map_len"

    assert {:error, _} = Engine.new(opts(%{max_input_len: 0}))
  end

  test "raises on out-of-protocol calls instead of corrupting the engine" do
    {:ok, engine} = Engine.new(opts())
    assert_raise ErlangError, ~r/no input is pending/, fn -> Engine.report(engine, :ok) end
    Engine.next(engine)
    assert_raise ErlangError, ~r/must be reported first/, fn -> Engine.next(engine) end
    assert_raise ArgumentError, fn -> Engine.report(engine, :bogus) end
    assert Engine.report(engine, :ok) in [:none, :corpus]
  end
end
