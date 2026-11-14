# Examples

> Examples don't lie.

This directory hosts example fuzz tests. Run one like any other test:

```sh
mix test examples/jason_test.exs
```

Or start fuzzing it, by line or name:

```sh
mix fuzz examples/jason_test.exs:6
mix fuzz examples/jason_test.exs:"fuzz Jason never crashes"
```
