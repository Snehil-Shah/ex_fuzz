defmodule ExFuzz.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_fuzz,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Fixture projects.
      test_ignore_filters: [~r"^test/fixtures/"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # ExFuzz's macros call ExUnit, and `mix fuzz` and the worker call Mix.
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      ex_fuzz: ex_fuzz(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Artifacts from fixtures.
  defp ex_fuzz(:test),
    do: [corpus_dir: "tmp/fuzz/corpus", cache_dir: "tmp/fuzz/cache", crash_dump_dir: "tmp/fuzz"]

  defp ex_fuzz(_), do: []

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:rustler, "~> 0.38.0", runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:benchee, "~> 1.5", only: :dev},
      # Fixture projects.
      {:sample_dep, path: "test/fixtures/sample_dep", only: :test}
    ]
  end
end
