//! The LibAFL driver.
//!
//! LibAFL is driven through its public `PushStage` trait (`init` / `pre_exec` / `post_exec` / `deinit`),
//! the same way LibAFL's own `PushStageAdapter` drives it, except that the caller runs each input.

use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::atomic::AtomicU8,
};

use libafl::{
    StdFuzzer,
    corpus::{Corpus, InMemoryCorpus, Testcase},
    events::NopEventManager,
    executors::ExitKind,
    feedback_or_fast,
    feedbacks::{CrashFeedback, MaxMapFeedback, TimeoutFeedback},
    inputs::{BytesInput, HasTargetBytes},
    mutators::{HavocScheduledMutator, havoc_mutations},
    observers::StdMapObserver,
    schedulers::{QueueScheduler, Scheduler},
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
    /// Maps to a one-element tuple of [`StdMapObserver`].
    observers: OT,
    /// The mutational push stage that produces inputs.
    /// Maps to [`StdMutationalPushStage`].
    stage: PS,
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
    PS: PushStage<EM, BytesInput, OT, S, Z>,
    S: HasCorpus<BytesInput> + HasSolutions<BytesInput> + HasExecutions,
{
    /// Hand the finished run to LibAFL (`post_exec`) and work out what it did with the input.
    fn report(&mut self, outcome: Outcome) -> Result<Verdict, Error> {
        let input = self
            .pending
            .take()
            .expect("Engine::report checks the protocol against awaiting_outcome()");
        *self.state.executions_mut() += 1;
        let corpus_before = self.state.corpus().count();
        let solutions_before = self.state.solutions().count();
        self.stage.post_exec(
            &mut self.fuzzer,
            &mut self.state,
            &mut self.mgr,
            &mut self.observers,
            input,
            outcome.into(),
        )?;
        Ok(if self.state.solutions().count() > solutions_before {
            Verdict::Solution
        } else if self.state.corpus().count() > corpus_before {
            Verdict::Corpus
        } else {
            Verdict::None
        })
    }

    /// Get the next mutated input from the push stage (`pre_exec`) and keep it pending.
    fn next(&mut self) -> Result<Vec<u8>, Error> {
        let input = self.next_input()?;
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
    PS: PushStage<EM, BytesInput, OT, S, Z>,
    S: HasCorpus<BytesInput> + HasSolutions<BytesInput> + HasExecutions,
{
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
    let observer = unsafe {
        StdMapObserver::from_mut_ptr(
            "coverage",
            counters.as_ptr().cast::<u8>().cast_mut(),
            counters.len(),
        )
    };
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

    let mut scheduler = QueueScheduler::new();
    let seeds = if config.seeds.is_empty() {
        vec![Vec::new()]
    } else {
        config.seeds
    };
    for seed in seeds {
        let id = state
            .corpus_mut()
            .add(Testcase::new(BytesInput::new(seed)))?;
        Scheduler::<BytesInput, _>::on_add(&mut scheduler, &mut state, id)?;
    }

    let fuzzer = StdFuzzer::new(scheduler, feedback, objective);
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
}
