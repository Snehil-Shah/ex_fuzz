defmodule ExFuzz.Coordinator do
  @moduledoc false

  # Runs a worker in a fuzz node, a child VM started with `:peer`, and relays its events.

  alias ExFuzz.{Runner, Worker}

  @type option :: {:report_to, Process.dest()} | Worker.option()
  @type result :: {:done, Runner.stats()} | {:error, term()} | {:node_down, term()}

  @doc """
  Fuzzes in a new fuzz node until the worker finishes, then stops the node.

  Relays the worker's `{:ex_fuzz, :solution | :stats, _}` events to `:report_to`. `:stop` sent to
  this process stops the worker. `{:node_down, reason}` means the fuzz node's VM died.

  Options:
    * `:report_to` (required) - where events are relayed.
    * `t:ExFuzz.Worker.option/0` - passed to `ExFuzz.Worker.start/2`.
  """
  @spec run([option()]) :: result()
  def run(opts) do
    {report_to, worker_opts} = Keyword.pop!(opts, :report_to)
    {:ok, peer, _node} = :peer.start(%{connection: :standard_io, peer_down: :crash})
    ref = Process.monitor(peer)

    try do
      :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
      {:ok, _apps} = :peer.call(peer, Application, :ensure_all_started, [:ex_fuzz])
      :ok = :peer.call(peer, Worker, :start, [self(), worker_opts])
      await(peer, ref, report_to)
    after
      Process.demonitor(ref, [:flush])
      stop(peer)
    end
  end

  defp await(peer, ref, report_to) do
    receive do
      {:ex_fuzz, :done, stats} ->
        {:done, stats}

      {:ex_fuzz, :error, reason} ->
        {:error, reason}

      {:ex_fuzz, _kind, _value} = event ->
        send(report_to, event)
        await(peer, ref, report_to)

      :stop ->
        :peer.send(peer, Worker, :stop)
        await(peer, ref, report_to)

      {:DOWN, ^ref, :process, ^peer, reason} ->
        {:node_down, reason}
    end
  end

  defp stop(peer) do
    :peer.stop(peer)
  catch
    # The node may already be gone.
    :exit, :noproc -> :ok
  end
end
