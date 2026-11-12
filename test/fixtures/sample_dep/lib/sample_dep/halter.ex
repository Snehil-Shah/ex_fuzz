defmodule SampleDep.Halter do
  @moduledoc false

  # Kills the VM on every input, as a crashing NIF or running out of memory would.

  def halt(_input), do: System.halt(7)

  # Halting with a message also makes the VM write a crash dump.
  def halt_with_dump(_input), do: :erlang.halt(~c"fixture crash")

  # As the OOM killer does.
  def kill(_input), do: System.cmd("kill", ["-KILL", System.pid()])
end
