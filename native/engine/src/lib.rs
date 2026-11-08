//! A coverage-guided fuzzing engine, exposed as a NIF.

mod coverage;
mod drivers;
mod fuzzer;

#[cfg(not(test))]
mod nif;

#[cfg(test)]
mod test;
