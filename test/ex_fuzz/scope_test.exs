defmodule ExFuzz.ScopeTest do
  use ExUnit.Case, async: true

  alias ExFuzz.Scope
  alias SampleDep.Scope.{Captured, Entry, Leaf, Middle}

  test "follows direct calls and captures, recursively, through the dependencies" do
    assert Enum.sort(Scope.modules([Entry])) == [Captured, Entry, Leaf, Middle]
  end

  test "never takes ex_fuzz's own modules, or Elixir's, even when the fuzz test calls them" do
    # The fuzzer can't probe itself.
    assert Scope.modules([ExFuzz.Executor, Enum, :lists]) == []
  end

  test "modules_called_by/2 resolves aliases, imports and captures" do
    alias SampleDep.Halter
    alias SampleDep.Planted, as: P
    import SampleDep.Classifier, only: [classify: 1]

    block =
      quote do
        P.check(data)
        classify(data)
        _ = &Halter.halt/1
        # A module held in a variable is only known at runtime.
        module.check(data)
      end

    called = Scope.modules_called_by(block, __ENV__)
    assert called == [SampleDep.Classifier, SampleDep.Halter, SampleDep.Planted]
  end
end
