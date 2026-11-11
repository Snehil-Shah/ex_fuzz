defmodule ExFuzz.ScopeTest do
  use ExUnit.Case, async: true

  alias ExFuzz.Scope
  alias MockDep.Scope.{Captured, Entry, Leaf, Middle}

  test "follows direct calls and captures, recursively, through the dependencies" do
    assert Enum.sort(Scope.modules([Entry])) == [Captured, Entry, Leaf, Middle]
  end

  test "never takes ex_fuzz's own modules, or Elixir's, even when the fuzz test calls them" do
    # The fuzzer can't probe itself.
    assert Scope.modules([ExFuzz.Executor, Enum, :lists]) == []
  end
end
