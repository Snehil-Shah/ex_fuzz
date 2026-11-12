defmodule ExFuzz.Fixtures.FuzzTest do
  use ExUnit.Case
  use ExFuzz

  @moduletag :fuzz_fixture

  fuzz "finds the planted bug", data <- binary(), seeds: ["AAAA"] do
    SampleDep.Planted.check(data)
  end

  fuzz "never crashes", data <- binary(), seeds: ["AAAA"] do
    SampleDep.Classifier.classify(data)
  end

  fuzz "is slow", data <- binary(), seeds: ["AAAA"] do
    Process.sleep(100)
    SampleDep.Classifier.classify(data)
  end

  # Calls only Elixir, which is never instrumented.
  fuzz "has nothing to instrument", data <- binary(), seeds: ["AAAA"] do
    byte_size(data)
  end

  fuzz "kills the VM", data <- binary(), seeds: ["AAAA"] do
    SampleDep.Halter.halt(data)
  end

  fuzz "kills the VM with a crash dump", data <- binary(), seeds: ["AAAA"] do
    SampleDep.Halter.halt_with_dump(data)
  end

  fuzz "is killed by a signal", data <- binary(), seeds: ["AAAA"] do
    SampleDep.Halter.kill(data)
  end

  describe "in a describe" do
    fuzz "never crashes", data <- binary(), seeds: ["AAAA"] do
      SampleDep.Classifier.classify(data)
    end

    fuzz "never crashes either", data <- binary(), seeds: ["AAAA"] do
      SampleDep.Classifier.classify(data)
    end
  end

  test "not a fuzz test" do
    :ok
  end
end
