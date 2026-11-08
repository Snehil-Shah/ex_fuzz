//! Integration tests.

use crate::coverage;
use crate::fuzzer::{Config, Engine, Outcome, Verdict};
use crate::test::support::lock_map;

/// Crashes only on inputs starting with "FUZZ".
fn planted_bug(input: &[u8], probes: bool) -> Outcome {
    let hit = |id| {
        if probes {
            coverage::hit(id)
        }
    };
    hit(0);
    for (depth, expected) in b"FUZZ".iter().enumerate() {
        if input.get(depth) != Some(expected) {
            return Outcome::Ok;
        }
        hit(depth + 1);
    }
    Outcome::Crash
}

/// Run the caller-owned loop until the objective fires or `budget` executions pass.
/// Returns the input that triggered the objective.
fn fuzz(engine: &mut Engine, budget: u64, target: impl Fn(&[u8]) -> Outcome) -> Option<Vec<u8>> {
    let mut step = engine.step(None).unwrap();
    for _ in 0..budget {
        let outcome = target(&step.input);
        let input = std::mem::take(&mut step.input);
        step = engine.step(Some(outcome)).unwrap();
        if step.previous == Verdict::Solution {
            return Some(input);
        }
    }
    None
}

/// Base config.
fn config() -> Config {
    Config {
        map_len: 8,
        max_input_len: 4096,
        rng_seed: Some(42),
        seeds: vec![b"AAAA".to_vec()],
    }
}

#[test]
fn finds_bug_behind_four_byte_magic_with_coverage() {
    let _lock = lock_map();
    let mut engine = Engine::new(config()).unwrap();
    let found = fuzz(&mut engine, 2_000_000, |input| planted_bug(input, true));
    let found = found.expect("planted bug not found within budget");
    assert!(found.starts_with(b"FUZZ"), "objective fired on {found:?}");
    assert_eq!(engine.stats().solutions, 1);
}

#[test]
fn does_not_find_bug_without_coverage() {
    // Control: the same search with no probes is blind (odds ~1 in 2^32 per input).
    let _lock = lock_map();
    let mut engine = Engine::new(config()).unwrap();
    assert_eq!(
        fuzz(&mut engine, 200_000, |input| planted_bug(input, false)),
        None
    );
}

#[test]
fn new_coverage_is_reported_as_corpus_verdict() {
    let _lock = lock_map();
    let mut engine = Engine::new(config()).unwrap();
    let corpus_before = engine.stats().corpus;
    engine.step(None).unwrap();
    // First execution touches probe 0 for the first time: new coverage.
    coverage::hit(0);
    let step = engine.step(Some(Outcome::Ok)).unwrap();
    assert_eq!(step.previous, Verdict::Corpus);
    assert_eq!(engine.stats().corpus, corpus_before + 1);
    // Same coverage again: not interesting.
    coverage::hit(0);
    let step = engine.step(Some(Outcome::Ok)).unwrap();
    assert_eq!(step.previous, Verdict::None);
    assert_eq!(engine.stats().executions, 2);
}

#[test]
fn crashes_and_timeouts_are_reported_as_solution_verdicts() {
    let _lock = lock_map();
    let mut engine = Engine::new(config()).unwrap();
    engine.step(None).unwrap();
    let step = engine.step(Some(Outcome::Crash)).unwrap();
    assert_eq!(step.previous, Verdict::Solution, "a crash is a solution");
    let step = engine.step(Some(Outcome::Timeout)).unwrap();
    assert_eq!(step.previous, Verdict::Solution, "a timeout is a solution");
    assert_eq!(engine.stats().solutions, 2);
}

#[test]
fn step_resets_the_coverage_map() {
    let _lock = lock_map();
    let mut engine = Engine::new(config()).unwrap();
    coverage::hit(3);
    engine.step(None).unwrap();
    assert_eq!(coverage::get(3), 0);
}

#[test]
fn generated_inputs_respect_max_input_len() {
    let _lock = lock_map();
    let mut engine = Engine::new(Config {
        max_input_len: 16,
        ..config()
    })
    .unwrap();
    let mut step = engine.step(None).unwrap();
    for i in 0..20_000 {
        assert!(
            step.input.len() <= 16,
            "input of {} bytes",
            step.input.len()
        );
        coverage::hit(i % 8);
        step = engine.step(Some(Outcome::Ok)).unwrap();
    }
}

#[test]
fn starts_from_an_empty_input_without_seeds() {
    let _lock = lock_map();
    let mut engine = Engine::new(Config {
        seeds: Vec::new(),
        ..config()
    })
    .unwrap();
    assert_eq!(engine.stats().corpus, 1);
    engine.step(None).unwrap();
}
