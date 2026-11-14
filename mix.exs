defmodule ExFuzz.MixProject do
  use Mix.Project

  # NOTE: Build time configuration. Version is patched during build.
  @version "0.0.0"

  @source_url "https://github.com/Snehil-Shah/ex_fuzz"

  def project do
    [
      app: :ex_fuzz,
      version: @version,
      description: "Coverage-guided fuzz testing for Elixir.",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      # Fixture projects.
      test_ignore_filters: [~r"^test/fixtures/"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # ExFuzz's macros call ExUnit, and `mix fuzz` and the worker call Mix.
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      ex_fuzz: ex_fuzz(Mix.env()),
      name: "ExFuzz",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  # Run "mix help hex.publish" to learn about packages.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(
        lib
        mix.exs
        README.md
        LICENSE
        checksum-*.exs
        native/engine/src
        native/engine/Cargo.toml
        Cargo.toml
        Cargo.lock
        .cargo
      )
    ]
  end

  # Run "mix help docs" to learn about documentation.
  defp docs do
    [
      main: "overview",
      source_ref: "v#{@version}",
      extras: ["guides/overview.md", "guides/corpus.md", "guides/configuration.md"]
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
      {:rustler_precompiled, "~> 0.10.1"},
      # Builds the NIF from source.
      {:rustler, "~> 0.38.0", optional: true, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:benchee, "~> 1.5", only: :dev},
      # Fixture projects.
      {:sample_dep, path: "test/fixtures/sample_dep", only: :test}
    ]
  end
end
