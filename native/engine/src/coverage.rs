//! The coverage map.
//!
//! One byte counter per probe. Instrumented code calls [`hit`] with its probe id,
//! the engine resets the map before each execution and reads it afterwards.
//!
//! SAFETY: no instrumented code runs while the engine resets or reads the map.

use std::ptr;
use std::sync::atomic::{
    AtomicPtr, AtomicU8,
    Ordering::{Acquire, Relaxed, Release},
};

/// The counters.
struct Map {
    counters: Box<[AtomicU8]>,
}

/// The current map.
static MAP: AtomicPtr<Map> = AtomicPtr::new(ptr::null_mut());

/// Initialize a zeroed map of `len` counters.
pub(crate) fn init(len: usize) -> &'static [AtomicU8] {
    let counters = (0..len).map(|_| AtomicU8::new(0)).collect();
    // NOTE: We don't free the older map, as some leftover process might be holding on.
    let map: &'static Map = Box::leak(Box::new(Map { counters }));
    MAP.store(ptr::from_ref(map).cast_mut(), Release);
    &map.counters
}

/// The current map's counters.
fn counters() -> &'static [AtomicU8] {
    let map = MAP.load(Acquire);
    // SAFETY: MAP is either null or points to a leaked `Map`, which is never freed.
    let map = unsafe { map.as_ref() }.expect("coverage map used before the engine created it");
    &map.counters
}

/// Record a probe hit.
pub(crate) fn hit(id: usize) {
    let counter = &counters()[id];

    // WARNING: This is intentionally not a thread-safe increment.
    // We lose a few counts, but we maintain perf under concurrency.
    let count = counter.load(Relaxed);

    // NOTE: on overflow the counter goes from 255 to 1.
    // From "AFL++: Combining Incremental Steps of Fuzzing Research"
    // which found it outperforms saturating at 255.
    // Ref: https://www.usenix.org/system/files/woot20-paper-fioraldi.pdf
    let next = if count == u8::MAX { 1 } else { count + 1 };

    counter.store(next, Relaxed);
}

/// Get a probe's current hit count.
pub(crate) fn get(id: usize) -> u8 {
    counters()[id].load(Relaxed)
}

/// Reset every counter to zero.
pub(crate) fn reset() {
    let counters = counters();
    // SAFETY: `AtomicU8` has the same layout as `u8`, so plain zero bytes are valid counters.
    unsafe { ptr::write_bytes(counters.as_ptr().cast_mut(), 0, counters.len()) };
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test::support::lock_map;

    /// Initialize a zeroed map of `len` counters.
    fn fresh_map(len: usize) -> (std::sync::MutexGuard<'static, ()>, &'static [AtomicU8]) {
        let guard = lock_map();
        (guard, init(len))
    }

    #[test]
    fn init_allocates_exactly_len_zeroed_counters() {
        let (_lock, map) = fresh_map(16);
        assert_eq!(map.len(), 16);
        assert!(map.iter().all(|c| c.load(Relaxed) == 0));
    }

    #[test]
    fn hit_increments_the_counter() {
        let (_lock, _map) = fresh_map(16);
        hit(7);
        hit(7);
        assert_eq!(get(7), 2);
        assert_eq!(get(8), 0);
    }

    #[test]
    fn counters_saturate_to_one() {
        let (_lock, _map) = fresh_map(16);
        for _ in 0..255 {
            hit(3);
        }
        assert_eq!(get(3), 255);
        hit(3);
        assert_eq!(get(3), 1, "255 wraps to 1");
    }

    #[test]
    #[should_panic]
    fn hit_outside_the_map_panics() {
        let (_lock, _map) = fresh_map(16);
        hit(16);
    }

    #[test]
    fn reset_zeroes_every_counter() {
        let (_lock, map) = fresh_map(16);
        hit(2);
        hit(15);
        reset();
        assert!(map.iter().all(|c| c.load(Relaxed) == 0));
    }

    #[test]
    fn init_replaces_the_map_and_leaves_the_old_one_intact() {
        let (_lock, old) = fresh_map(16);
        hit(3);
        let new = init(16);
        assert_eq!(get(3), 0, "probes now write to the new map");
        hit(3);
        assert_eq!(new[3].load(Relaxed), 1);
        assert_eq!(
            old[3].load(Relaxed),
            1,
            "the old map is untouched, not freed"
        );
    }

    #[test]
    fn concurrent_hits_never_overcount() {
        // Hits from many threads may lose increments, but must never invent hits.
        let (_lock, _map) = fresh_map(64);
        let (threads, hits_each) = (8, 31); // 248 total: stays below the 255 overflow
        std::thread::scope(|scope| {
            for _ in 0..threads {
                scope.spawn(|| {
                    for _ in 0..hits_each {
                        hit(42);
                    }
                });
            }
        });
        let count = usize::from(get(42));
        assert!((1..=threads * hits_each).contains(&count), "count {count}");
    }
}
