//! The fuzzing engine.
//!
//! [`Driver`] is the engine's contract. Implementations live in [`crate::drivers`].
//!
//! SAFETY: The coverage map is process-wide, so only one engine should be stepping at a time per OS process.

use std::fmt;

use crate::coverage;

/// Engine configuration.
#[derive(Debug, Clone)]
pub struct Config {
    /// Number of probes.
    pub map_len: usize,
    /// Upper bound on generated input length, in bytes.
    pub max_input_len: usize,
    /// Seed for the engine's random number generator. `None` seeds from the clock.
    pub rng_seed: Option<u64>,
    /// Initial corpus. If empty, the engine starts from a single empty input.
    pub seeds: Vec<Vec<u8>>,
}

/// How the target finished running an input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// No issues. Maps to [`ExitKind::Ok`](libafl::executors::ExitKind::Ok).
    Ok,
    /// A crash. Maps to [`ExitKind::Crash`](libafl::executors::ExitKind::Crash).
    Crash,
    /// The run timed out. Maps to [`ExitKind::Timeout`](libafl::executors::ExitKind::Timeout).
    Timeout,
}

/// What the engine did with the previous input once its outcome was reported.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    /// No previous input or it was not interesting.
    None,
    /// It reached new coverage and was added to the corpus.
    Corpus,
    /// It triggered the objective (a crash or timeout) and was added to the solutions.
    Solution,
}

/// Result of one [`Engine::step`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    /// The next input to run.
    pub input: Vec<u8>,
    /// Verdict on the previous input.
    pub previous: Verdict,
}

/// The engine's progress so far.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    /// Inputs in the corpus, seeds included.
    pub corpus: usize,
    /// Inputs that triggered the objective (crashes and timeouts).
    pub solutions: usize,
    /// Inputs whose outcome has been reported.
    pub executions: u64,
}

/// Why an engine call failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// The configuration was rejected.
    InvalidConfig(String),
    /// `step` was called out of protocol (see [`Engine::step`]).
    Protocol(&'static str),
    /// The driver reported an error.
    Engine(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidConfig(msg) => write!(f, "invalid engine config: {msg}"),
            Error::Protocol(msg) => write!(f, "engine protocol error: {msg}"),
            Error::Engine(msg) => write!(f, "engine error: {msg}"),
        }
    }
}

impl std::error::Error for Error {}

/// A fuzzing engine.
pub struct Engine {
    inner: Box<dyn Driver>,
}

impl Engine {
    /// Create an engine with a new coverage map.
    pub fn new(config: Config) -> Result<Self, Error> {
        if config.map_len == 0 {
            return Err(Error::InvalidConfig("map_len must be at least 1".into()));
        }
        if config.max_input_len == 0 {
            return Err(Error::InvalidConfig(
                "max_input_len must be at least 1".into(),
            ));
        }
        let counters = coverage::init(config.map_len);
        Ok(Self {
            // TODO: drivers will eventually be configurable via experimental flags.
            inner: crate::drivers::libafl::build(config, counters)?,
        })
    }

    /// Report the previous input's outcome and get the next input to run.
    ///
    /// Protocol: the first call passes `None`, every later call passes the outcome of the
    /// input returned by the call before it. The coverage map is reset just before this
    /// returns, so run the input right away.
    pub fn step(&mut self, previous: Option<Outcome>) -> Result<Step, Error> {
        match (self.inner.awaiting_outcome(), previous) {
            (true, None) => {
                return Err(Error::Protocol(
                    "an outcome is required for the pending input",
                ));
            }
            (false, Some(_)) => {
                return Err(Error::Protocol(
                    "an outcome was given but no input is pending",
                ));
            }
            _ => {}
        }
        let step = self.inner.step(previous)?;
        coverage::reset();
        Ok(step)
    }

    /// Progress statistics.
    pub fn stats(&self) -> Stats {
        self.inner.stats()
    }
}

/// Driver contract.
pub(crate) trait Driver: Send {
    /// See [`Engine::step`].
    fn step(&mut self, previous: Option<Outcome>) -> Result<Step, Error>;
    /// See [`Engine::stats`].
    fn stats(&self) -> Stats;
    /// Whether the last `step` handed out an input whose outcome hasn't been reported yet.
    fn awaiting_outcome(&self) -> bool;
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex, MutexGuard};

    use super::*;
    use crate::test::support::lock_map;

    /// Config with no seeds and a clock-seeded RNG.
    fn base(map_len: usize, max_input_len: usize) -> Config {
        Config {
            map_len,
            max_input_len,
            rng_seed: None,
            seeds: Vec::new(),
        }
    }

    #[test]
    fn rejects_invalid_config() {
        assert!(matches!(
            Engine::new(base(0, 4096)),
            Err(Error::InvalidConfig(_))
        ));
        assert!(matches!(
            Engine::new(base(8, 0)),
            Err(Error::InvalidConfig(_))
        ));
    }

    /// The `previous` value of every call a `CallRecordingDriver` receives, shared with the test.
    type Calls = Arc<Mutex<Vec<Option<Outcome>>>>;

    /// Mock driver that records the `previous` value of every call it receives.
    struct CallRecordingDriver {
        calls: Calls,
        pending: bool,
    }

    impl Driver for CallRecordingDriver {
        fn step(&mut self, previous: Option<Outcome>) -> Result<Step, Error> {
            self.calls.lock().unwrap().push(previous);
            self.pending = true;
            Ok(Step {
                input: Vec::new(),
                previous: Verdict::None,
            })
        }

        fn stats(&self) -> Stats {
            Stats::default()
        }

        fn awaiting_outcome(&self) -> bool {
            self.pending
        }
    }

    /// An engine around a `CallRecordingDriver`, plus a handle to the calls the driver receives.
    fn call_recording_engine() -> (MutexGuard<'static, ()>, Engine, Calls) {
        let guard = lock_map();
        coverage::init(8);
        let calls = Arc::new(Mutex::new(Vec::new()));
        let engine = Engine {
            inner: Box::new(CallRecordingDriver {
                calls: calls.clone(),
                pending: false,
            }),
        };
        (guard, engine, calls)
    }

    #[test]
    fn first_step_must_not_report_an_outcome() {
        let (_lock, mut engine, calls) = call_recording_engine();
        assert_eq!(
            engine.step(Some(Outcome::Ok)),
            Err(Error::Protocol(
                "an outcome was given but no input is pending"
            ))
        );
        assert!(
            calls.lock().unwrap().is_empty(),
            "driver must not be called"
        );
    }

    #[test]
    fn later_steps_must_report_an_outcome() {
        let (_lock, mut engine, calls) = call_recording_engine();
        engine.step(None).unwrap();
        assert_eq!(
            engine.step(None),
            Err(Error::Protocol(
                "an outcome is required for the pending input"
            ))
        );
        assert_eq!(*calls.lock().unwrap(), vec![None]);
    }

    #[test]
    fn protocol_errors_leave_the_pending_input_reportable() {
        let (_lock, mut engine, calls) = call_recording_engine();
        engine.step(None).unwrap();
        assert!(engine.step(None).is_err());
        engine.step(Some(Outcome::Crash)).unwrap();
        assert_eq!(*calls.lock().unwrap(), vec![None, Some(Outcome::Crash)]);
    }

    /// Mock driver that records the value of probe 0 at the moment its `step` runs.
    struct MapReadingDriver {
        seen: Arc<Mutex<Vec<u8>>>,
    }

    impl Driver for MapReadingDriver {
        fn step(&mut self, _previous: Option<Outcome>) -> Result<Step, Error> {
            self.seen.lock().unwrap().push(coverage::get(0));
            Ok(Step {
                input: Vec::new(),
                previous: Verdict::None,
            })
        }

        fn stats(&self) -> Stats {
            Stats::default()
        }

        fn awaiting_outcome(&self) -> bool {
            false
        }
    }

    #[test]
    fn step_resets_the_map_after_the_driver_has_read_it() {
        let _lock = lock_map();
        coverage::init(8);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let mut engine = Engine {
            inner: Box::new(MapReadingDriver { seen: seen.clone() }),
        };
        coverage::hit(0);
        engine.step(None).unwrap();
        assert_eq!(
            *seen.lock().unwrap(),
            vec![1],
            "the driver read the map before the reset"
        );
        assert_eq!(
            coverage::get(0),
            0,
            "the engine reset the map after the driver returned"
        );
    }

    #[test]
    fn new_allocates_a_map_of_exactly_map_len() {
        let _lock = lock_map();
        let _engine = Engine::new(base(16, 4096)).unwrap();
        assert_eq!(coverage::get(15), 0, "the last probe is inside the map");
        let out_of_range = std::panic::catch_unwind(|| coverage::hit(16));
        assert!(
            out_of_range.is_err(),
            "probe 16 is outside a 16-counter map"
        );
    }
}
