//! Media failures and keepalive failures use different evidence. A confirmed probe does not prove that pictures arrive.
use std::collections::VecDeque;
use std::time::Duration;
use tokio::time::Instant;

#[derive(Default)]
pub(super) struct UdpTrials {
    failed_openers: usize,
    interrupted: VecDeque<Instant>,
}

impl UdpTrials {
    pub fn opened(&mut self) {
        self.failed_openers = 0;
    }

    pub fn retry_opener(&mut self) -> bool {
        self.failed_openers += 1;
        self.failed_openers < 3
    }

    pub fn retry_playback(&mut self, now: Instant) -> bool {
        self.interrupted.retain(|at| now.saturating_duration_since(*at) <= Duration::from_secs(10));
        if self.interrupted.back().is_none_or(|at| now.saturating_duration_since(*at) >= Duration::from_millis(250)) {
            self.interrupted.push_back(now);
        }
        self.interrupted.len() < 3
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repeated_reference_loss_counts_across_commits_but_not_across_a_quiet_interval() {
        let now = Instant::now();
        let mut trials = UdpTrials::default();
        assert!(trials.retry_playback(now));
        assert!(trials.retry_playback(now + Duration::from_millis(20)));
        assert!(trials.retry_playback(now + Duration::from_secs(3)));
        trials.opened();
        assert!(!trials.retry_playback(now + Duration::from_secs(5)));
        assert!(trials.retry_playback(now + Duration::from_secs(16)));
        assert!(trials.retry_opener());
        assert!(trials.retry_opener());
        assert!(!trials.retry_opener());
        trials.opened();
        assert!(trials.retry_opener());
    }
}
