# Engine

> A coverage-guided fuzzing engine, exposed as a NIF.

A performant driver-agnostic fuzzing engine contract with multiple driver implementations (TBD) in `src/drivers`. This currently implements a LibAFL driver for all the steps except the actual executions. Actual execution loops reside in Elixir that calls instrumented BEAM code, and interacts with engine components via NIF for acting on the instrumented measurements (outcomes, mutations, corpus-building etc.).