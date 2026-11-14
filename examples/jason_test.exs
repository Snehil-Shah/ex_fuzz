defmodule JasonTest do
  use ExUnit.Case
  use ExFuzz

  @tag timeout: 100
  fuzz "Jason never crashes", data <- binary(), seeds: ["{}", "[1]"] do
    with {:ok, term} <- Jason.decode(data) do
      assert Jason.decode!(Jason.encode!(term)) == term
    end
  end
end
