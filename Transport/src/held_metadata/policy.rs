//! Closed purposes: verification never inherits the hydration exclusion.
use super::*;
#[derive(Clone, Copy)]
pub(crate) enum Eligibility {
    StrictContent,
    SyncHydration,
}

pub(super) fn qualify(
    snapshot: &Snapshot,
    purpose: Eligibility,
    sync_check: impl Fn() -> bool,
) -> Result<()> {
    // A complete default-only inventory needs no metadata exclusion. Keep the
    // historical data-read eligibility for both purposes, including HIDDEN
    // stages and readonly/system files; no Darwin policy call is involved.
    if snapshot.streams.iter().all(|s| s.name == "::$DATA") {
        return Ok(());
    }
    if matches!(purpose, Eligibility::StrictContent) {
        return Err(unsupported());
    }
    for stream in &snapshot.streams {
        if stream.name == "::$DATA" {
            continue;
        }
        const NAME: &str = ":com.apple.provenance:$DATA";
        if stream.name != NAME
            || stream.name_utf16 != NAME.encode_utf16().collect::<Vec<_>>()
            || stream.name_length_bytes != 54
            || stream.logical_size != 11
            || stream.allocation_size != 11
        {
            return Err(unsupported());
        }
    }
    // These bounds qualify the NEW named-metadata exclusion only. They never
    // restrict an ordinary default-only read or grant mutation authority.
    let a = snapshot.entry.attributes;
    if snapshot.links != 1
        || snapshot.ea_size_bytes != 0
        || a & !(32 | 128) != 0
        || (a & 128 != 0 && a != 128)
        || !sync_check()
    {
        return Err(unsupported());
    }
    Ok(())
}

/// Public Darwin name-policy API. Only the fixed name and SYNC intent are
/// consulted; no remote values/names/configuration influence this check.
#[cfg(target_os = "macos")]
pub(crate) fn sync_exclusion_allowed() -> bool {
    use std::ffi::{c_char, c_int, c_uint};
    #[link(name = "System")]
    extern "C" {
        fn xattr_preserve_for_intent(name: *const c_char, intent: c_uint) -> c_int;
    }
    // SDK sys/xattr_flags.h: XATTR_OPERATION_INTENT_SYNC = 4 (macOS10.10+).
    unsafe { xattr_preserve_for_intent(c"com.apple.provenance".as_ptr(), 4) == 0 }
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn sync_exclusion_allowed() -> bool {
    false
}
