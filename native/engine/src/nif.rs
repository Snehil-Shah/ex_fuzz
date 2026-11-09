//! The Erlang bindings.

use std::sync::{Mutex, MutexGuard};

use crate::coverage;
use crate::fuzzer::{Config, Engine, Outcome, Verdict};
use rustler::{Atom, Binary, Env, NewBinary, NifMap, NifResult, ResourceArc};

mod atoms {
    rustler::atoms! { ok, crash, timeout, none, corpus, solution }
}

/// An engine held by Erlang as a resource (mutex allows one caller at a time).
struct EngineResource(Mutex<Engine>);

#[rustler::resource_impl]
impl rustler::Resource for EngineResource {}

/// Engine options, decoded from an Elixir map.
#[derive(NifMap)]
struct EngineOpts<'a> {
    map_len: usize,
    max_input_len: usize,
    rng_seed: Option<u64>,
    seeds: Vec<Binary<'a>>,
}

/// Engine stats, encoded as an Elixir map.
#[derive(NifMap)]
struct EngineStats {
    corpus: usize,
    solutions: usize,
    executions: u64,
}

/// Coverage probe. Instrumented code calls this at the start of every clause body.
#[rustler::nif]
fn hit(id: usize) -> Atom {
    coverage::hit(id);
    atoms::ok()
}

/// Get a probe's current hit count.
#[rustler::nif]
fn coverage_get(id: usize) -> u8 {
    coverage::get(id)
}

/// Returns `{:ok, engine}` or `{:error, message}`.
#[rustler::nif]
fn new(opts: EngineOpts) -> Result<ResourceArc<EngineResource>, String> {
    let config = Config {
        map_len: opts.map_len,
        max_input_len: opts.max_input_len,
        rng_seed: opts.rng_seed,
        seeds: opts
            .seeds
            .iter()
            .map(|seed| seed.as_slice().to_vec())
            .collect(),
    };
    let engine = Engine::new(config).map_err(|e| e.to_string())?;
    Ok(ResourceArc::new(EngineResource(Mutex::new(engine))))
}

/// Report the previous outcome and get `{next_input, verdict_on_previous}`.
#[rustler::nif]
fn step<'a>(
    env: Env<'a>,
    engine: ResourceArc<EngineResource>,
    previous: Atom,
) -> NifResult<(Binary<'a>, Atom)> {
    let previous = decode_outcome(previous)?;
    let step = lock(&engine)?
        .step(previous)
        .map_err(|e| raise(&e.to_string()))?;

    let mut binary = NewBinary::new(env, step.input.len());
    binary.as_mut_slice().copy_from_slice(&step.input);
    Ok((binary.into(), encode_verdict(step.previous)))
}

/// Report the pending input's outcome and get the verdict on it.
#[rustler::nif]
fn report(engine: ResourceArc<EngineResource>, outcome: Atom) -> NifResult<Atom> {
    let outcome = decode_outcome(outcome)?.ok_or(rustler::Error::BadArg)?;
    let verdict = lock(&engine)?
        .report(outcome)
        .map_err(|e| raise(&e.to_string()))?;
    Ok(encode_verdict(verdict))
}

/// Get the engine's stats.
#[rustler::nif]
fn stats(engine: ResourceArc<EngineResource>) -> NifResult<EngineStats> {
    let stats = lock(&engine)?.stats();
    Ok(EngineStats {
        corpus: stats.corpus,
        solutions: stats.solutions,
        executions: stats.executions,
    })
}

/// `:none` for the first step, otherwise `:ok | :crash | :timeout`.
fn decode_outcome(atom: Atom) -> NifResult<Option<Outcome>> {
    if atom == atoms::none() {
        Ok(None)
    } else if atom == atoms::ok() {
        Ok(Some(Outcome::Ok))
    } else if atom == atoms::crash() {
        Ok(Some(Outcome::Crash))
    } else if atom == atoms::timeout() {
        Ok(Some(Outcome::Timeout))
    } else {
        Err(rustler::Error::BadArg)
    }
}

/// `:none | :corpus | :solution`.
fn encode_verdict(verdict: Verdict) -> Atom {
    match verdict {
        Verdict::None => atoms::none(),
        Verdict::Corpus => atoms::corpus(),
        Verdict::Solution => atoms::solution(),
    }
}

/// Lock the engine for this call.
fn lock(engine: &EngineResource) -> NifResult<MutexGuard<'_, Engine>> {
    engine
        .0
        .lock()
        .map_err(|_| raise("engine mutex poisoned by an earlier panic"))
}

/// Raise `message` as an Erlang exception.
fn raise(message: &str) -> rustler::Error {
    rustler::Error::RaiseTerm(Box::new(message.to_string()))
}

rustler::init!("Elixir.ExFuzz.Engine");
