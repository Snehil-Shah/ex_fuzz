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

/// [`coverage::hit`], returning `:ok`. Instrumented code calls this at the start of every clause body.
#[rustler::nif]
fn hit(id: usize) -> Atom {
    coverage::hit(id);
    atoms::ok()
}

/// [`coverage::get`], as an integer.
#[rustler::nif]
fn coverage_get(id: usize) -> u8 {
    coverage::get(id)
}

/// [`Engine::new`]: `{:ok, engine}` or `{:error, message}`.
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

/// [`Engine::next`], returning the input as a binary.
#[rustler::nif]
fn next<'a>(env: Env<'a>, engine: ResourceArc<EngineResource>) -> NifResult<Binary<'a>> {
    let input = lock(&engine)?.next().map_err(|e| raise(&e.to_string()))?;

    let mut binary = NewBinary::new(env, input.len());
    binary.as_mut_slice().copy_from_slice(&input);
    Ok(binary.into())
}

/// [`Engine::report`], returning the verdict as an atom.
#[rustler::nif]
fn report(engine: ResourceArc<EngineResource>, outcome: Atom) -> NifResult<Atom> {
    let outcome = decode_outcome(outcome)?;
    let verdict = lock(&engine)?
        .report(outcome)
        .map_err(|e| raise(&e.to_string()))?;
    Ok(encode_verdict(verdict))
}

/// [`Engine::stats`], as an Elixir map.
#[rustler::nif]
fn stats(engine: ResourceArc<EngineResource>) -> NifResult<EngineStats> {
    let stats = lock(&engine)?.stats();
    Ok(EngineStats {
        corpus: stats.corpus,
        solutions: stats.solutions,
        executions: stats.executions,
    })
}

/// `:ok | :crash | :timeout`.
fn decode_outcome(atom: Atom) -> NifResult<Outcome> {
    if atom == atoms::ok() {
        Ok(Outcome::Ok)
    } else if atom == atoms::crash() {
        Ok(Outcome::Crash)
    } else if atom == atoms::timeout() {
        Ok(Outcome::Timeout)
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
