defmodule ExFuzz.Engine do
  @moduledoc false

  # See: `native/engine`.

  # WARNING: There can be only one engine per VM at a time as the coverage map is shared per OS process.
  # New engine replaces the older one. That means only one target can be fuzzed at a time per VM.

  # Protocol: the caller runs each input between two calls, in this order:
  #
  #   1. `next/1` hands out an input, which is then pending.
  #   2. The caller runs it.
  #   3. `report/2` scores the pending input's outcome.
  #
  # A call out of this order raises.

  project = Mix.Project.config()

  # Dependencies compile in `:prod`, so users download the NIF built by the release workflow.
  use RustlerPrecompiled,
    otp_app: :ex_fuzz,
    crate: "engine",
    base_url: "#{project[:source_url]}/releases/download/v#{project[:version]}",
    version: project[:version],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-unknown-linux-musl
    ),
    nif_versions: ["2.15"],
    force_build: Mix.env() in [:dev, :test] or System.get_env("EX_FUZZ_BUILD") in ["1", "true"]

  @type engine :: reference()
  @type outcome :: :ok | :crash | :timeout
  @type verdict :: :none | :corpus | :solution

  @typedoc """
  Engine options.

    * `:map_len` - the number of probes. At least 1.
    * `:max_input_len` - the upper bound on generated input length, in bytes. At least 1.
    * `:rng_seed` - seeds the random number generator, for reproducible runs. `nil` seeds from the clock.
    * `:seeds` - the initial corpus. If empty, the engine starts from a single empty input.
  """
  @type opts :: %{
          map_len: pos_integer(),
          max_input_len: pos_integer(),
          rng_seed: non_neg_integer() | nil,
          seeds: [binary()]
        }

  @typedoc """
  The engine's progress so far.

    * `:corpus` - inputs in the corpus, seeds included.
    * `:solutions` - inputs that crashed or timed out.
    * `:executions` - inputs whose outcome has been reported.
  """
  @type stats :: %{
          corpus: non_neg_integer(),
          solutions: non_neg_integer(),
          executions: non_neg_integer()
        }

  @doc "Coverage probe: records that probe `id` was reached."
  @spec hit(non_neg_integer()) :: :ok
  def hit(_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Coverage probe: records that probe `id` was reached and returns `value` as a tail call.

  Use this for clauses with constant bodies to avoid reserving a stack frame.
  """
  @spec hit(non_neg_integer(), value) :: value when value: term()
  def hit(id, value) do
    hit(id)
    value
  end

  @doc """
  Current value of probe `id`'s counter.
  """
  @spec coverage_get(non_neg_integer()) :: 0..255
  def coverage_get(_id), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Creates an engine."
  @spec new(opts()) :: {:ok, engine()} | {:error, String.t()}
  def new(_opts), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Hands out the next input to run. It stays pending until `report/2`.

  The coverage map is reset just before this returns, so run the input right away.
  """
  @spec next(engine()) :: binary()
  def next(_engine), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Reports the pending input's outcome and returns the verdict on it."
  @spec report(engine(), outcome()) :: verdict()
  def report(_engine, _outcome), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Progress statistics."
  @spec stats(engine()) :: stats()
  def stats(_engine), do: :erlang.nif_error(:nif_not_loaded)
end
