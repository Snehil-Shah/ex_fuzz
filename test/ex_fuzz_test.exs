defmodule ExFuzzTest do
  use ExUnit.Case
  doctest ExFuzz

  test "greets the world" do
    assert ExFuzz.hello() == :world
  end
end
