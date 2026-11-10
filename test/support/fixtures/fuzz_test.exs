defmodule ExFuzz.Fixtures.FuzzTest do
  use ExUnit.Case
  use ExFuzz

  @moduletag :fuzz_fixture

  setup do
    %{check: &ExFuzz.Fixtures.Planted.check/1}
  end

  fuzz "finds the planted bug", data <- binary(), %{check: check}, seeds: ["AAAA"] do
    check.(data)
  end

  fuzz "never crashes", data <- binary(), seeds: ["AAAA"] do
    ExFuzz.Fixtures.Classifier.classify(data)
  end

  fuzz "kills the VM", data <- binary(), seeds: ["AAAA"] do
    ExFuzz.Fixtures.Halter.halt(data)
  end

  fuzz "kills the VM with a crash dump", data <- binary(), seeds: ["AAAA"] do
    ExFuzz.Fixtures.Halter.halt_with_dump(data)
  end

  describe "in a describe" do
    fuzz "never crashes", data <- binary(), seeds: ["AAAA"] do
      ExFuzz.Fixtures.Classifier.classify(data)
    end

    fuzz "never crashes either", data <- binary(), seeds: ["AAAA"] do
      ExFuzz.Fixtures.Classifier.classify(data)
    end
  end

  test "not a fuzz test" do
    :ok
  end
end
