# Overview

> Coverage-guided fuzz testing for Elixir.

The quickest and easiest way to start fuzzing your Elixir projects!

```elixir
defmodule JasonTest do
  use ExUnit.Case
  use ExFuzz

  @tag timeout: 100
  fuzz "Jason never crashes", data <- binary(), seeds: ["{}", "[1]"] do
    with {:ok, term} <- Jason.decode(data) do
      assert Jason.decode!(Jason.encode!(term)) == term
    end
  end
end
```

ExFuzz is well-integrated with ExUnit so your fuzz tests can run alongside your regular tests and use the seed corpus as an ever-growing regression suite.

## What is fuzz testing?

Fuzz testing runs your code with a stream of generated inputs, looking for ones that crash it or fail an assertion. Coverage-guided fuzzing watches which code each input reaches and builds on the inputs that reach new code, so it finds edge cases that hand-written tests miss.

If you're interested in learning more, see [The Fuzzing Book](https://www.fuzzingbook.org/).

## Requirements

ExFuzz requires:

* Elixir 1.16+
* Erlang/OTP 26+
* macOS or Linux (x86_64 or arm64, glibc 2.34+ or musl)

## Installation

Add `ex_fuzz` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_fuzz, ">= 0.0.0", only: [:dev, :test]}
  ]
end
```

Then run `mix deps.get` to install it from [Hex](https://hex.pm/packages/ex_fuzz).

> #### Note {: .info}
>
> On unsupported platforms, build ExFuzz from source: install Rust, add `{:rustler, "~> 0.38.0", runtime: false}` to your dependencies, and set `EX_FUZZ_BUILD=1`.

## Quick start

Fuzz tests, defined with `ExFuzz.fuzz/5`, run with the rest of your suite under `mix test`. To run only them:

```sh
mix test --only fuzz
```

To start fuzzing a target, point `mix fuzz` at the test by its line or name:

```sh
mix fuzz test/jason_test.exs:6
mix fuzz test/jason_test.exs:"fuzz Jason never crashes"
```

Failing inputs are saved as [seed corpus](corpus.md) to `test/fixtures/fuzz/` and replayed by `mix test` from then on.
To save them elsewhere, see [Configuration](configuration.md).

## Next steps

* [Corpus](corpus.md) - seeds, saved inputs and the cache.
* [Configuration](configuration.md) - options to customize ExFuzz.
* [GitHub](https://github.com/Snehil-Shah/ex_fuzz) - source code, releases and issues.
