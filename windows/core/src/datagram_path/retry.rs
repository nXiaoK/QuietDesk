//! Cooldown of the viewer's direct UDP path while reliable video remains usable.
use std::time::Duration;
use tokio::time::Instant;

const BACKOFF: [Duration; 4] = [Duration::from_secs(30), Duration::from_secs(60), Duration::from_secs(120), Duration::from_secs(300)];
const STABLE: Duration = Duration::from_secs(300);

#[derive(Default)]
pub(super) struct Recovery {
    failures: usize,
    next: Option<Instant>,
    selected: Option<Instant>,
    paused_at: Option<Instant>,
}

impl Recovery {
    pub fn deadline(&self) -> Option<Instant> {
        if self.paused_at.is_none() { self.next } else { None }
    }

    pub fn selected(&mut self, now: Instant) {
        self.next = None;
        self.selected = Some(self.paused_at.unwrap_or(now));
    }

    pub fn failed(&mut self, now: Instant) {
        let now = self.paused_at.unwrap_or(now);
        if self.selected.take().is_some_and(|at| now.saturating_duration_since(at) >= STABLE) {
            self.failures = 0;
        }
        let delay = BACKOFF[self.failures.min(BACKOFF.len() - 1)];
        self.failures = (self.failures + 1).min(BACKOFF.len());
        self.next = Some(now + delay);
    }

    pub fn pause(&mut self, paused: bool, now: Instant) {
        if paused {
            self.paused_at.get_or_insert(now);
        } else if let Some(start) = self.paused_at.take() {
            let freeze = |at: &mut Instant| *at += now.saturating_duration_since(start);
            self.next.iter_mut().for_each(freeze);
            self.selected.iter_mut().for_each(freeze);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_closed_driver_while_paused_starts_its_cooldown_on_resume() {
        let start = Instant::now();
        let mut policy = Recovery::default();
        policy.selected(start);
        policy.pause(true, start);
        policy.failed(start + Duration::from_secs(10));
        let resumed = start + Duration::from_secs(20);
        policy.pause(false, resumed);
        assert_eq!(policy.deadline(), Some(resumed + BACKOFF[0]));
    }

    #[test]
    fn repeated_loss_backs_off_and_five_minutes_of_active_delivery_resets_the_budget() {
        let mut now = Instant::now();
        let mut policy = Recovery::default();
        for delay in [30, 60, 120, 300, 300] {
            policy.failed(now);
            assert_eq!(policy.deadline(), Some(now + Duration::from_secs(delay)));
            now = policy.deadline().unwrap();
            policy.selected(now);
            assert!(policy.deadline().is_none());
            now += Duration::from_secs(1);
        }
        policy.pause(true, now);
        now += STABLE;
        policy.pause(false, now);
        policy.failed(now);
        assert_eq!(policy.deadline(), Some(now + BACKOFF[3]));
        policy.pause(true, now);
        assert!(policy.deadline().is_none());
        now += STABLE;
        policy.pause(false, now);
        assert_eq!(policy.deadline(), Some(now + BACKOFF[3]));
        now = policy.deadline().unwrap();
        policy.selected(now);
        now += STABLE;
        policy.failed(now);
        assert_eq!(policy.deadline(), Some(now + BACKOFF[0]));
    }
}
