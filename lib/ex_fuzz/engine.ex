defmodule ExFuzz.Engine do
  @moduledoc false

  # See: `native/engine`.

  use Rustler, otp_app: :ex_fuzz, crate: "engine"

  @type engine :: reference()
  @type outcome :: :ok | :crash | :timeout
  @type verdict :: :none | :corpus | :solution
  @type engine_opts :: %{
          required(:map_len) => pos_integer(),
          required(:max_input_len) => pos_integer(),
          required(:rng_seed) => non_neg_integer() | nil,
          required(:seeds) => [binary()]
        }

  @doc "Coverage probe: records that probe `id` was reached."
  @spec hit(non_neg_integer()) :: :ok
  def hit(_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Current value of probe `id`'s counter.
  """
  @spec coverage_get(non_neg_integer()) :: 0..255
  def coverage_get(_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an engine."
  @spec new(engine_opts()) :: {:ok, engine()} | {:error, String.t()}
  def new(_opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Reports the previous input's outcome and returns the next input to run.

  Pass `:none` on the first call, then the outcome of each returned input.
  The coverage map is reset just before this returns, so run the input right away.
  """
  @spec step(engine(), outcome() | :none) :: {binary(), verdict()}
  def step(_engine, _previous), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Progress statistics."
  @spec stats(engine()) :: %{
          corpus: non_neg_integer(),
          solutions: non_neg_integer(),
          executions: non_neg_integer()
        }
  def stats(_engine), do: :erlang.nif_error(:nif_not_loaded)
end
