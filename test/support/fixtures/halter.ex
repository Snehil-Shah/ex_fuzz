defmodule ExFuzz.Fixtures.Halter do
  @moduledoc false

  # Kills the VM on every input, as a crashing NIF or running out of memory would.

  def halt(_input), do: System.halt(7)
end
