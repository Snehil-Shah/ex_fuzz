//! The LibAFL driver.
//!
//! LibAFL is driven through its public `PushStage` trait (`init` / `pre_exec` / `post_exec` / `deinit`),
//! the same way LibAFL's own `PushStageAdapter` drives it, except that the caller runs each input.

use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    rc::Rc,
    sync::atomic::AtomicU8,
};

use libafl::{
    StdFuzzer,
    corpus::{Corpus, InMemoryCorpus},
    events::NopEventManager,
    executors::ExitKind,
    feedback_or_fast,
    feedbacks::{CrashFeedback, MaxMapFeedback, TimeoutFeedback},
    fuzzer::{ExecuteInputResult, ExecutionProcessor},
    inputs::{BytesInput, HasTargetBytes},
    mutators::{HavocScheduledMutator, havoc_mutations},
    observers::{HitcountsMapObserver, ObserversTuple, StdMapObserver},
    schedulers::QueueScheduler,
    stages::push::{PushStage, StdMutationalPushStage},
    state::{HasCorpus, HasExecutions, HasMaxSize, HasSolutions, StdState},
};
use libafl_bolts::{ToSlice, current_nanos, rands::StdRand, tuples::tuple_list};

use crate::fuzzer::{Config, Driver, Error, Outcome, Stats, Verdict};

impl From<Outcome> for ExitKind {
    fn from(outcome: Outcome) -> Self {
        match outcome {
            Outcome::Ok => ExitKind::Ok,
            Outcome::Crash => ExitKind::Crash,
            Outcome::Timeout => ExitKind::Timeout,
        }
    }
}

impl From<libafl::Error> for Error {
    fn from(e: libafl::Error) -> Self {
        Error::Engine(e.to_string())
    }
}

/// The engine's LibAFL parts, plus the state needed to drive a push stage step by step.
struct LibAflDriver<Z, S, EM, OT, PS> {
    /// Scheduler, feedback and objective.
    /// Maps to [`StdFuzzer`] (built in [`build`]).
    fuzzer: Z,
    /// RNG, corpus, solutions, execution count and metadata.
    /// Maps to [`StdState`].
    state: S,
    /// Event manager. A no-op for now (no stats reporting or multi-process sync).
    /// Maps to [`NopEventManager`].
    mgr: EM,
    /// The coverage map observer.
    /// Maps to a one-element tuple of [`HitcountsMapObserver`] over a [`StdMapObserver`].
    observers: OT,
    /// The mutational push stage that produces inputs.
    /// Maps to [`StdMutationalPushStage`].
    stage: PS,
    /// Seeds not yet run. `next` hands out the front one, `report` pops it once done.
    seeds: VecDeque<BytesInput>,
    /// Input handed out by the last `next`, awaiting its outcome.
    pending: Option<BytesInput>,
    /// Whether the push stage is mid-round (between `init` and `deinit`).
    in_round: bool,
}

// SAFETY: LibAFL's push stage holds `Rc`s, which are `!Send` because clones could be used from
// two threads at once. Every such clone lives inside this one driver (created in `build`, never
// shared elsewhere) and is reachable only through `&mut self`, so moving the whole driver to another
// thread moves all clones together and no two threads can touch them concurrently.
unsafe impl<Z, S, EM, OT, PS> Send for LibAflDriver<Z, S, EM, OT, PS> {}

impl<Z, S, EM, OT, PS> Driver for LibAflDriver<Z, S, EM, OT, PS>
where
    Z: ExecutionProcessor<EM, BytesInput, OT, S>,
    PS: PushStage<EM, BytesInput, OT, S, Z>,
    S: HasCorpus<BytesInput> + HasSolutions<BytesInput> + HasExecutions,
    OT: ObserversTuple<BytesInput, S>,
{
    /// Hand the finished run to LibAFL and work out what it did with the input.
    fn report(&mut self, outcome: Outcome) -> Result<Verdict, Error> {
        let input = self
            .pending
            .take()
            .expect("Engine::report checks the protocol against awaiting_outcome()");
        *self.state.executions_mut() += 1;
        let corpus_before = self.state.corpus().count();
        let solutions_before = self.state.solutions().count();
        let exit_kind = outcome.into();

        // We run inputs ourselves instead of through a LibAFL executor, so nothing else calls
        // the observers' post-run hook. That hook is what buckets the hit counts.
        self.observers
            .post_exec_all(&mut self.state, &input, &exit_kind)?;

        // Add to corpus if it's a seed.
        let seed = self.seeds.pop_front().is_some();
        if seed {
            self.add_seed(&input, exit_kind)?;
        } else {
            self.stage.post_exec(
                &mut self.fuzzer,
                &mut self.state,
                &mut self.mgr,
                &mut self.observers,
                input,
                exit_kind,
            )?;
        }

        Ok(if self.state.solutions().count() > solutions_before {
            Verdict::Solution
        } else if !seed && self.state.corpus().count() > corpus_before {
            Verdict::Corpus
        } else {
            Verdict::None
        })
    }

    /// Hand out the next seed or mutated input from LibAFL.
    fn next(&mut self) -> Result<Vec<u8>, Error> {
        let input = match self.seeds.front() {
            Some(seed) => seed.clone(),
            None => self.next_input()?,
        };
        let bytes = input.target_bytes().to_slice().to_vec();
        self.pending = Some(input);
        Ok(bytes)
    }

    /// Read the counts from LibAFL's state.
    fn stats(&self) -> Stats {
        Stats {
            corpus: self.state.corpus().count(),
            solutions: self.state.solutions().count(),
            executions: *self.state.executions(),
        }
    }

    fn awaiting_outcome(&self) -> bool {
        self.pending.is_some()
    }
}

impl<Z, S, EM, OT, PS> LibAflDriver<Z, S, EM, OT, PS>
where
    Z: ExecutionProcessor<EM, BytesInput, OT, S>,
    PS: PushStage<EM, BytesInput, OT, S, Z>,
    S: HasCorpus<BytesInput> + HasSolutions<BytesInput> + HasExecutions,
{
    /// Add a seed to the corpus after its run.
    fn add_seed(&mut self, input: &BytesInput, exit_kind: ExitKind) -> Result<(), Error> {
        let result = match self.fuzzer.check_results(
            &mut self.state,
            &mut self.mgr,
            input,
            &self.observers,
            &exit_kind,
        )? {
            ExecuteInputResult::None => ExecuteInputResult::Corpus,
            result => result,
        };
        self.fuzzer.process_execution(
            &mut self.state,
            &mut self.mgr,
            input,
            &result,
            &exit_kind,
            &self.observers,
        )?;
        Ok(())
    }

    /// Get the next mutated input from the push stage, starting a new round when needed.
    fn next_input(&mut self) -> Result<BytesInput, Error> {
        loop {
            if !self.in_round {
                self.stage.init(
                    &mut self.fuzzer,
                    &mut self.state,
                    &mut self.mgr,
                    &mut self.observers,
                )?;
                self.in_round = true;
            }
            match self.stage.pre_exec(
                &mut self.fuzzer,
                &mut self.state,
                &mut self.mgr,
                &mut self.observers,
            ) {
                Some(result) => return Ok(result?),
                None => {
                    self.stage.deinit(
                        &mut self.fuzzer,
                        &mut self.state,
                        &mut self.mgr,
                        &mut self.observers,
                    )?;
                    self.in_round = false;
                }
            }
        }
    }
}

/// Assemble the LibAFL parts for a validated `config`, observing the engine's `counters`.
pub(crate) fn build(
    config: Config,
    counters: &'static [AtomicU8],
) -> Result<Box<dyn Driver>, Error> {
    // SAFETY: the pointer is valid for `counters.len()` bytes for the rest of the program,
    // since the map is leaked, never freed. `AtomicU8` has the same layout as `u8`.
    let map = unsafe {
        StdMapObserver::from_mut_ptr(
            "coverage",
            counters.as_ptr().cast::<u8>().cast_mut(),
            counters.len(),
        )
    };
    // Bucket the counts like AFL (1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+), so a loop running
    // one more time isn't new coverage.
    let observer = HitcountsMapObserver::new(map);
    let mut feedback = MaxMapFeedback::new(&observer);
    // A run is a bug if it crashed or timed out.
    let mut objective = feedback_or_fast!(CrashFeedback::new(), TimeoutFeedback::new());
    let rng = StdRand::with_seed(config.rng_seed.unwrap_or_else(current_nanos));
    let mut state = StdState::new(
        rng,
        InMemoryCorpus::<BytesInput>::new(),
        InMemoryCorpus::<BytesInput>::new(),
        &mut feedback,
        &mut objective,
    )?;
    state.set_max_size(config.max_input_len);

    let seeds: VecDeque<BytesInput> = if config.seeds.is_empty() {
        VecDeque::from([BytesInput::new(Vec::new())])
    } else {
        config.seeds.into_iter().map(BytesInput::new).collect()
    };

    let fuzzer = StdFuzzer::new(QueueScheduler::new(), feedback, objective);
    let stage = StdMutationalPushStage::new(
        HavocScheduledMutator::new(havoc_mutations()),
        // Only used by the `Iterator` path, which we don't use.
        Rc::new(RefCell::new(None)),
        Rc::new(Cell::new(None)),
    );
    Ok(Box::new(LibAflDriver {
        fuzzer,
        state,
        mgr: NopEventManager::new(),
        observers: tuple_list!(observer),
        stage,
        seeds,
        pending: None,
        in_round: false,
    }))
}

#[cfg(test)]
mod tests {
    use libafl::stages::push::mutational::DEFAULT_MUTATIONAL_MAX_ITERATIONS;

    use super::*;
    use crate::coverage;
    use crate::test::support::lock_map;

    fn config() -> Config {
        Config {
            map_len: 8,
            max_input_len: 4096,
            rng_seed: Some(42),
            seeds: vec![b"AAAA".to_vec()],
        }
    }

    #[test]
    fn awaiting_outcome_follows_the_pending_input() {
        let _lock = lock_map();
        let mut driver = build(config(), coverage::init(8)).unwrap();
        assert!(!driver.awaiting_outcome(), "nothing handed out yet");
        driver.next().unwrap();
        assert!(driver.awaiting_outcome(), "an input is out");
        driver.report(Outcome::Ok).unwrap();
        assert!(!driver.awaiting_outcome(), "the input was reported");
    }

    #[test]
    #[should_panic(expected = "Engine::report checks the protocol")]
    fn out_of_protocol_call_is_unreachable() {
        // `Engine` rejects this call before it reaches the driver.
        let _lock = lock_map();
        let mut driver = build(config(), coverage::init(8)).unwrap();
        let _ = driver.report(Outcome::Ok);
    }

    #[test]
    fn keeps_producing_inputs_across_many_rounds() {
        // A round yields at most DEFAULT_MUTATIONAL_MAX_ITERATIONS inputs, so this many steps
        // crosses at least 10 round boundaries (`deinit`, then `init` of the next round).
        let _lock = lock_map();
        let mut driver = build(config(), coverage::init(8)).unwrap();
        for _ in 0..10 * DEFAULT_MUTATIONAL_MAX_ITERATIONS {
            driver.next().unwrap();
            driver.report(Outcome::Ok).unwrap();
        }
    }

    /// A driver seeded with `seeds`.
    fn seeded(seeds: &[&[u8]]) -> Box<dyn Driver> {
        let seeds = seeds.iter().map(|seed| seed.to_vec()).collect();
        build(Config { seeds, ..config() }, coverage::init(8)).unwrap()
    }

    /// Run one input that ends with `outcome`. Returns the input and its verdict.
    fn run(driver: &mut Box<dyn Driver>, outcome: Outcome) -> (Vec<u8>, Verdict) {
        let input = driver.next().unwrap();
        (input, driver.report(outcome).unwrap())
    }

    #[test]
    fn seeds_run_first_as_they_are_and_in_order() {
        let _lock = lock_map();
        let mut driver = seeded(&[b"one", b"two", b"three"]);
        for seed in [&b"one"[..], b"two", b"three"] {
            assert_eq!(run(&mut driver, Outcome::Ok).0, seed);
        }
    }

    #[test]
    fn starts_from_an_empty_input_without_seeds() {
        let _lock = lock_map();
        let mut driver = seeded(&[]);
        assert_eq!(run(&mut driver, Outcome::Ok).0, b"");
    }

    #[test]
    fn every_seed_joins_the_corpus_without_being_a_new_find() {
        let _lock = lock_map();
        let mut driver = seeded(&[b"one", b"two", b"three"]);
        assert_eq!(
            driver.stats().corpus,
            0,
            "nothing is in the corpus before it has run"
        );

        let verdicts: Vec<Verdict> = (0..3).map(|_| run(&mut driver, Outcome::Ok).1).collect();

        assert_eq!(verdicts, [Verdict::None; 3], "a seed is not a new find");
        assert_eq!(
            driver.stats().corpus,
            3,
            "even though none reached new coverage"
        );
    }

    #[test]
    fn a_failing_seed_is_a_solution() {
        let _lock = lock_map();
        let mut driver = seeded(&[b"one"]);
        assert_eq!(run(&mut driver, Outcome::Crash).1, Verdict::Solution);
        assert_eq!(driver.stats().solutions, 1);
        assert_eq!(
            driver.stats().corpus,
            0,
            "a failing seed is not a corpus entry"
        );
    }

    #[test]
    fn mutation_starts_once_every_seed_has_run() {
        let _lock = lock_map();
        let mut driver = seeded(&[b"one", b"two"]);
        run(&mut driver, Outcome::Ok);
        run(&mut driver, Outcome::Ok);
        assert_eq!(driver.stats().corpus, 2);

        run(&mut driver, Outcome::Ok);
        assert_eq!(driver.stats().executions, 3, "the two seeds and a mutation");
    }

    #[test]
    fn crashes_and_timeouts_are_solutions() {
        let _lock = lock_map();
        let mut driver = seeded(&[b"AAAA"]);
        run(&mut driver, Outcome::Ok);

        assert_eq!(run(&mut driver, Outcome::Crash).1, Verdict::Solution);
        assert_eq!(run(&mut driver, Outcome::Timeout).1, Verdict::Solution);
        assert_eq!(driver.stats().solutions, 2);
    }

    /// Run one input that hits probe 0 `hits` times. Returns its verdict.
    fn run_hitting(driver: &mut Box<dyn Driver>, hits: usize) -> Verdict {
        driver.next().unwrap();
        coverage::reset();
        for _ in 0..hits {
            coverage::hit(0);
        }
        driver.report(Outcome::Ok).unwrap()
    }

    #[test]
    fn more_hits_in_the_same_bucket_are_not_new_coverage() {
        let _lock = lock_map();
        let mut driver = seeded(&[b"AAAA"]);
        run_hitting(&mut driver, 5);
        assert_eq!(
            run_hitting(&mut driver, 7),
            Verdict::None,
            "5 and 7 are both in the 4-7 bucket"
        );
        assert_eq!(
            run_hitting(&mut driver, 8),
            Verdict::Corpus,
            "8 starts the next bucket"
        );
    }

    #[test]
    fn one_two_and_three_hits_are_different_buckets() {
        let _lock = lock_map();
        let mut driver = seeded(&[b"AAAA"]);
        run_hitting(&mut driver, 0);
        for hits in 1..=3 {
            assert_eq!(run_hitting(&mut driver, hits), Verdict::Corpus, "{hits}");
        }
    }

    #[test]
    fn generated_inputs_respect_max_input_len() {
        let _lock = lock_map();
        let mut driver = build(
            Config {
                max_input_len: 16,
                ..config()
            },
            coverage::init(8),
        )
        .unwrap();
        for _ in 0..20_000 {
            let (input, _verdict) = run(&mut driver, Outcome::Ok);
            assert!(input.len() <= 16, "input of {} bytes", input.len());
        }
    }
}
