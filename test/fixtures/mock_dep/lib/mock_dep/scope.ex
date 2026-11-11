defmodule MockDep.Scope.Entry do
  @moduledoc false

  # A call chain for `ExFuzz.Scope`.

  def run(list) do
    list |> Enum.map(&MockDep.Scope.Captured.inc/1) |> MockDep.Scope.Middle.run()
  end
end

defmodule MockDep.Scope.Middle do
  @moduledoc false

  def run(list), do: MockDep.Scope.Leaf.run(:lists.reverse(list))
end

defmodule MockDep.Scope.Leaf do
  @moduledoc false

  def run(list), do: list
end

defmodule MockDep.Scope.Captured do
  @moduledoc false

  # Only ever captured, never called directly.
  def inc(x), do: x + 1
end

defmodule MockDep.Scope.Unused do
  @moduledoc false

  # Nothing calls it.
  def run(list), do: list
end
