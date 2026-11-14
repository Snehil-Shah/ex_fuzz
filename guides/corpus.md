# Corpus

A fuzz test's corpus is the set of inputs it keeps. It comes from three places.

## Seeds

The `:seeds` you give a fuzz test are example inputs. `mix test` runs each of them, and `mix fuzz` runs and uses them as the base for mutation.

```elixir
fuzz "Jason never crashes", data <- binary(), seeds: ["{}", "[1]"] do
```

## Saved inputs

When `mix fuzz` finds an input that fails the test, it saves it as seed corpus to [`:corpus_dir`](configuration.md#options):

```
** (ExFuzz.Error) got RuntimeError (boom)
input: "[1,"
file:  test/fixtures/fuzz/JasonTest/Jason_never_crashes/616b86e4dec8d1b7
rerun: mix test test/jason_test.exs:6
```

From then on, `mix test` replays it with the seeds, and fails until the bug is fixed:

```
** (ExFuzz.Error) got RuntimeError (boom)
seed:  "[1,"
file:  test/fixtures/fuzz/JasonTest/Jason_never_crashes/616b86e4dec8d1b7
```

Each test has its own directory, named after its module and test name.

> #### Commit your corpus {: .tip}
>
> Commit your corpus directory with your tests. Every input saved there keeps failing `mix test` until the bug is fixed.

## Cache

While fuzzing, inputs that reach new code are cached in [`:cache_dir`](configuration.md#options) (`_build/ex_fuzz/corpus/` by default) to save local progress. The next `mix fuzz` starts from them, so it picks up where the last run left off. `mix test` doesn't use the cache, and you shouldn't commit it, as it can grow large.
