# Bench

> Numbers don't lie.

Most architectural decisions behind this project were made keeping performance in mind. One of the major things that makes fuzzing effective is high throughput: the more inputs per second, the sooner fuzzing reaches new code.

This directory hosts benchmarking scripts measuring the core components. You may run them as:

```sh
mix run bench/<script>.exs
```
