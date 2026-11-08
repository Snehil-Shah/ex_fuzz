defmodule ExFuzz.Fixtures.Branches do
  @moduledoc false

  # Two paths through each kind of clause: function heads, fn, receive, and try/rescue.

  def head(1), do: :one
  def head(_), do: :other

  def anon(x) do
    f = fn
      1 -> :one
      _ -> :other
    end

    f.(x)
  end

  def recv(msg) do
    send(self(), msg)

    receive do
      {:ping, _} -> :pong
      _ -> :other
    end
  end

  def rescued(x) do
    try do
      if x == :boom, do: raise("boom"), else: :fine
    rescue
      _ -> :rescued
    end
  end
end
