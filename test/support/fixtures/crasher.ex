defmodule ExFuzz.Fixtures.Crasher do
  @moduledoc false

  def crash, do: raise("crash")
end
