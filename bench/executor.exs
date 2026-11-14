# The executor's cost per input.
# Run: mix run bench/executor.exs

alias ExFuzz.Executor

target = fn _input -> :ok end

Benchee.run(%{
  "direct call" => fn -> target.("input") end,
  "Executor.run" => fn -> Executor.run(target, "input", timeout: 1_000) end
})
