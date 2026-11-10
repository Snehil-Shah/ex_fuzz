# Fixture fuzz tests run only inside worker nodes.
ExUnit.start(exclude: [:fuzz_fixture])
