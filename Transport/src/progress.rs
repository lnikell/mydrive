//! Sample completed writes without inventing bytes or timer-driven progress.
use std::time::Duration;

#[derive(Default)]
pub(super) struct ProgressGate {
    last: Option<(u64, Duration)>,
}

impl ProgressGate {
    /// `elapsed` comes from the operation's monotonic Instant. The first
    /// positive sample is immediate; later changed samples are capped at 10 Hz.
    /// Completion bypasses this sampling gate and carries its exact byte count.
    pub(super) fn should_emit(&mut self, bytes: u64, elapsed: Duration) -> bool {
        if bytes == 0 {
            return false;
        }
        if let Some((previous_bytes, previous_time)) = self.last {
            if bytes <= previous_bytes
                || elapsed.saturating_sub(previous_time) < Duration::from_millis(100)
            {
                return false;
            }
        }
        self.last = Some((bytes, elapsed));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_positive_write_is_immediate_even_for_small_files() {
        let mut gate = ProgressGate::default();
        assert!(!gate.should_emit(0, Duration::ZERO));
        assert!(gate.should_emit(1, Duration::ZERO));
        assert!(!gate.should_emit(1, Duration::from_secs(1)));
        assert!(gate.should_emit(2, Duration::from_secs(1)));
    }

    #[test]
    fn byte_volume_cannot_bypass_the_monotonic_rate_limit() {
        let mut gate = ProgressGate::default();
        assert!(gate.should_emit(256 * 1024, Duration::ZERO));
        assert!(!gate.should_emit(128 * 1024 * 1024, Duration::from_millis(99)));
        assert!(gate.should_emit(128 * 1024 * 1024, Duration::from_millis(100)));
        assert!(!gate.should_emit(u64::MAX, Duration::from_millis(199)));
        assert!(gate.should_emit(u64::MAX, Duration::from_millis(200)));
    }

    #[test]
    fn duplicates_regressions_and_clock_regressions_do_not_advance_the_gate() {
        let mut gate = ProgressGate::default();
        assert!(gate.should_emit(20, Duration::from_secs(1)));
        assert!(!gate.should_emit(19, Duration::from_secs(2)));
        assert!(!gate.should_emit(20, Duration::from_secs(2)));
        assert!(!gate.should_emit(21, Duration::from_millis(900)));
        assert!(gate.should_emit(21, Duration::from_millis(1100)));
    }

    #[test]
    fn dense_byte_updates_emit_at_most_once_per_hundred_milliseconds() {
        let mut gate = ProgressGate::default();
        let emitted: Vec<_> = (0..=1_000)
            .filter(|&millis| {
                gate.should_emit((millis + 1) * 65_536, Duration::from_millis(millis))
            })
            .collect();
        assert_eq!(emitted, (0..=1_000).step_by(100).collect::<Vec<_>>());
    }
}
