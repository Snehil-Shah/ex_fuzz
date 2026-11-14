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
    for _ in 0..budget {
        let input = engine.next().unwrap();
        if engine.report(target(&input)).unwrap() == Verdict::Solution {
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
    // The seed first.
    engine.next().unwrap();
    engine.report(Outcome::Ok).unwrap();

    engine.next().unwrap();
    coverage::hit(0);
    assert_eq!(
        engine.report(Outcome::Ok),
        Ok(Verdict::Corpus),
        "probe 0, first reached"
    );
    engine.next().unwrap();
    coverage::hit(0);
    assert_eq!(
        engine.report(Outcome::Ok),
        Ok(Verdict::None),
        "probe 0 again"
    );
    assert_eq!(engine.stats().corpus, 2);
}
