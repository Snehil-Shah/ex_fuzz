//! Helpers shared by tests across the crate.

use std::sync::{Mutex, MutexGuard};

static MAP_LOCK: Mutex<()> = Mutex::new(());

/// The coverage map is process-wide and cargo runs tests on parallel threads,
/// so every test that touches the map holds this lock.
pub(crate) fn lock_map() -> MutexGuard<'static, ()> {
    MAP_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}
