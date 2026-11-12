defmodule SampleDep.Planted do
  @moduledoc false

  # Raises only on inputs starting with "FUZZ".

  def check(<<?F, rest::binary>>), do: u(rest)
  def check(_), do: :ok

  defp u(<<?U, rest::binary>>), do: z(rest)
  defp u(_), do: :ok

  defp z(<<?Z, rest::binary>>), do: zz(rest)
  defp z(_), do: :ok

  defp zz(<<?Z, _::binary>>), do: raise("planted")
  defp zz(_), do: :ok
end
