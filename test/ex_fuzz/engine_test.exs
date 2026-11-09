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
  defp fuzz(engine, target, budget) do
    {input, :none} = Engine.step(engine, :none)
    loop(engine, target, input, budget)
  end

  defp loop(_engine, _target, _input, 0), do: nil

  defp loop(engine, target, input, budget) do
    outcome =
      try do
        target.(input)
        :ok
      rescue
        _ -> :crash
      end

    case Engine.step(engine, outcome) do
      {_next, :solution} -> input
      {next, _verdict} -> loop(engine, target, next, budget - 1)
    end
  end

  test "probes write into the coverage map and a step resets it" do
    {:ok, engine} = Engine.new(opts())
    Engine.hit(5)
    Engine.hit(5)
    assert Engine.coverage_get(5) == 2
    Engine.step(engine, :none)
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
    Engine.step(engine, :none)
    Engine.hit(0)
    assert {_, :corpus} = Engine.step(engine, :ok)
    Engine.hit(0)
    assert {_, :none} = Engine.step(engine, :ok)
  end

  test "reports crashes and timeouts as :solution verdicts" do
    {:ok, engine} = Engine.new(opts())
    Engine.step(engine, :none)
    assert {_, :solution} = Engine.step(engine, :crash)
    assert {_, :solution} = Engine.step(engine, :timeout)
    assert %{solutions: 2} = Engine.stats(engine)
  end

  test "report returns the verdict on the pending input and hands out no new one" do
    {:ok, engine} = Engine.new(opts())
    Engine.step(engine, :none)
    assert Engine.report(engine, :crash) == :solution
    assert_raise ErlangError, ~r/no input is pending/, fn -> Engine.report(engine, :ok) end
    assert {_, :none} = Engine.step(engine, :none)
    assert_raise ArgumentError, fn -> Engine.report(engine, :none) end
  end

  test "rejects invalid options with an error tuple" do
    assert {:error, message} = Engine.new(opts(%{map_len: 0}))
    assert message =~ "map_len"

    assert {:error, _} = Engine.new(opts(%{max_input_len: 0}))
  end

  test "raises on out-of-protocol steps instead of corrupting the engine" do
    {:ok, engine} = Engine.new(opts())
    assert_raise ErlangError, ~r/no input is pending/, fn -> Engine.step(engine, :ok) end
    Engine.step(engine, :none)
    assert_raise ErlangError, ~r/outcome is required/, fn -> Engine.step(engine, :none) end
    assert {_, _} = Engine.step(engine, :ok)
    assert_raise ArgumentError, fn -> Engine.step(engine, :bogus) end
  end
end
