# Configuration

ExFuzz reads its configuration from the `:ex_fuzz` key of your project in `mix.exs`:

```elixir
def project do
  [
    app: :my_app,
    ex_fuzz: [
      corpus_dir: "test/fixtures/fuzz",
      cache_dir: "_build/ex_fuzz/corpus",
      crash_dump_dir: "_build/ex_fuzz"
    ]
  ]
end
```

## Options

* `:corpus_dir` - directory to store failing inputs as seed corpus. Defaults to `"test/fixtures/fuzz"`.
* `:cache_dir` - directory to cache fuzzing progress. Defaults to `"_build/ex_fuzz/corpus"`.
* `:crash_dump_dir` - directory to store crash dumps during fuzzing. Defaults to `"_build/ex_fuzz"`.

Paths are relative to your project's root.
