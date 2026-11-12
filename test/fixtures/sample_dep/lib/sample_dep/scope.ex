defmodule SampleDep.Scope.Entry do
  @moduledoc false

  # A call chain for `ExFuzz.Scope`.

  def run(list) do
    list |> Enum.map(&SampleDep.Scope.Captured.inc/1) |> SampleDep.Scope.Middle.run()
  end
end

defmodule SampleDep.Scope.Middle do
  @moduledoc false

  def run(list), do: SampleDep.Scope.Leaf.run(:lists.reverse(list))
end

defmodule SampleDep.Scope.Leaf do
  @moduledoc false

  def run(list), do: list
end

defmodule SampleDep.Scope.Captured do
  @moduledoc false

  # Only ever captured, never called directly.
  def inc(x), do: x + 1
end

defmodule SampleDep.Scope.Unused do
  @moduledoc false

  # Nothing calls it.
  def run(list), do: list
end
