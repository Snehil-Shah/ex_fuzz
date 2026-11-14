defmodule ExFuzz.Config do
  @moduledoc false

  # Project configuration.
  #
  #     def project do
  #       [ex_fuzz: [corpus_dir: "test/fixtures/fuzz"], ...]
  #     end

  @defaults [
    # Directory to store failing inputs as seed corpus.
    corpus_dir: "test/fixtures/fuzz",
    # Directory to cache fuzzing progress.
    cache_dir: "_build/ex_fuzz/corpus",
    # Directory to store crash dumps during fuzzing.
    crash_dump_dir: "_build/ex_fuzz"
  ]

  @doc "Get configuration value for `key`."
  @spec get(:corpus_dir | :cache_dir | :crash_dump_dir) :: Path.t()
  def get(key) do
    (Mix.Project.config()[:ex_fuzz] || [])
    |> Keyword.validate!(@defaults)
    |> Keyword.fetch!(key)
  end
end
