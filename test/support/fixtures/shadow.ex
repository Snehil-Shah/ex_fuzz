defmodule ExFuzz.Fixtures.Shadow do
  @moduledoc false

  # Defines and calls `size/1`, an auto-imported BIF name: it must still call its own function.

  def size(_), do: :mine
  def call(x), do: size(x)
end
