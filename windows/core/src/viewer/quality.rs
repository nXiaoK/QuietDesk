use crate::media::{MediaControl, MediaPath, MediaStreamId};
use crate::messages::StreamSettings;
use std::time::Duration;
use tokio::time::Instant;

const SAMPLE_WINDOW: Duration = Duration::from_secs(1);
const BASE_RECOVERY_HOLD: Duration = Duration::from_secs(8);
const MAX_RECOVERY_HOLD: Duration = Duration::from_secs(64);
const PROBATION: Duration = Duration::from_secs(15);

#[derive(Default)]
struct Window {
    bytes: usize,
    frames: u32,
    delivery_ms: Option<f64>,
    encode_ms: Option<f64>,
    repair: bool,
}

struct Sample {
    duration: Duration,
    frames: u32,
    megabits: f64,
    delivery_ms: Option<f64>,
    rtt_growth_ms: Option<f64>,
    encode_ms: Option<f64>,
    repair: bool,
}

/// A request is a suggestion until confirmed. The chosen ceiling survives changes to the actual stream.
struct BitratePolicy {
    ceiling: i64,
    host_ceiling: Option<i64>,
    last_change: Instant,
    healthy: Duration,
    congested: Duration,
    recovery_hold: Duration,
    upgraded_at: Option<Instant>,
}

impl BitratePolicy {
    fn new(ceiling: i64, now: Instant) -> Self {
        Self {
            ceiling,
            host_ceiling: None,
            last_change: now,
            healthy: Duration::ZERO,
            congested: Duration::ZERO,
            recovery_hold: BASE_RECOVERY_HOLD,
            upgraded_at: None,
        }
    }

    fn reset_evidence(&mut self) {
        self.healthy = Duration::ZERO;
        self.congested = Duration::ZERO;
    }

    fn reset_backoff(&mut self) {
        self.recovery_hold = BASE_RECOVERY_HOLD;
        self.upgraded_at = None;
    }

    fn choose(&mut self, ceiling: i64, now: Instant) {
        self.ceiling = ceiling;
        self.last_change = now;
        self.reset_evidence();
        self.reset_backoff();
    }

    fn confirm(&mut self, requested: i64, previous: i64, applied: i64, automatic: bool, succeeded: bool, now: Instant) {
        self.last_change = now;
        self.reset_evidence();
        if !succeeded {
            if automatic && requested > previous {
                self.recovery_hold = (self.recovery_hold * 2).min(MAX_RECOVERY_HOLD);
            }
            return;
        }
        if applied < requested || self.host_ceiling.is_some_and(|ceiling| applied > ceiling) {
            self.host_ceiling = Some(applied);
        }
        if automatic && applied > previous {
            self.upgraded_at = Some(now);
        } else if automatic && applied < previous && self.upgraded_at.take().is_some_and(|at| now - at < PROBATION) {
            self.recovery_hold = (self.recovery_hold * 2).min(MAX_RECOVERY_HOLD);
        }
    }

    fn suggest(&mut self, applied: StreamSettings, sample: Sample, now: Instant) -> Option<i64> {
        if self.upgraded_at.is_some_and(|at| now - at >= PROBATION) {
            self.upgraded_at = None;
            self.recovery_hold = BASE_RECOVERY_HOLD;
        }
        // A few accepted predicted frames show the encoder has work. Silence and isolated loss
        // do not tell us that the target bitrate is filling the connection.
        if sample.frames < 3 || sample.duration > SAMPLE_WINDOW * 3 {
            self.reset_evidence();
            return None;
        }
        let current = applied.megabits as f64;
        let delivery = sample.delivery_ms.unwrap_or(0.0);
        let rtt_growth = sample.rtt_growth_ms.unwrap_or(0.0);
        let saturated = sample.megabits <= current * 0.9;
        let congested = delivery >= 150.0 || rtt_growth >= 90.0 && (delivery >= 80.0 || sample.repair && saturated);
        if congested {
            self.congested += sample.duration;
            self.healthy = Duration::ZERO;
            let severe = delivery >= 500.0;
            if now - self.last_change < SAMPLE_WINDOW || (!severe && self.congested < SAMPLE_WINDOW * 2) {
                return None;
            }
            let target = if severe { current * 0.5 } else { current * 0.75 };
            // Use observed throughput to converge faster on a sustained narrow link.
            let target = target.min((sample.megabits * 1.25).ceil()).max(1.0);
            return StreamSettings::BIT_RATES.into_iter().rfind(|&rate| rate < applied.megabits && rate as f64 <= target);
        }

        self.congested = Duration::ZERO;
        let encode_budget_ms = 1_000.0 / applied.frames_per_second as f64;
        let healthy = (sample.delivery_ms.is_some() || sample.rtt_growth_ms.is_some())
            && delivery < 70.0
            && rtt_growth < 50.0
            && sample.megabits >= current * 0.55
            && sample.encode_ms.is_none_or(|ms| ms < encode_budget_ms);
        if !healthy {
            self.healthy = Duration::ZERO;
            return None;
        }
        self.healthy += sample.duration;
        if self.healthy < self.recovery_hold || now - self.last_change < self.recovery_hold {
            return None;
        }
        let ceiling = self.ceiling.min(self.host_ceiling.unwrap_or(self.ceiling));
        StreamSettings::BIT_RATES.into_iter().find(|&rate| rate > applied.megabits && rate <= ceiling)
    }
}

pub(super) struct AdaptiveQuality {
    policy: BitratePolicy,
    stream: Option<MediaStreamId>,
    committed_path: Option<MediaPath>,
    window: Window,
    started: Instant,
    control_rtt_ms: Option<(f64, Instant)>,
    rtt_floor_ms: Option<(f64, Instant)>,
}

impl AdaptiveQuality {
    pub(super) fn new(ceiling: i64, now: Instant) -> Self {
        Self {
            policy: BitratePolicy::new(ceiling, now),
            stream: None,
            committed_path: None,
            window: Window::default(),
            started: now,
            control_rtt_ms: None,
            rtt_floor_ms: None,
        }
    }

    pub(super) fn use_stream(&mut self, route: Option<(MediaStreamId, MediaPath)>, now: Instant) {
        let stream = route.map(|(stream, _)| stream);
        if stream != self.stream {
            if let Some((_, path)) = route
                && self.committed_path.replace(path).is_some_and(|previous| previous != path)
            {
                self.policy.reset_backoff();
            }
            self.stream = stream;
            self.window = Window::default();
            self.started = now;
            self.control_rtt_ms = None;
            self.rtt_floor_ms = None;
            self.policy.reset_evidence();
        }
    }

    pub(super) fn deadline(&self) -> Option<Instant> {
        self.stream.map(|_| self.started + SAMPLE_WINDOW)
    }

    pub(super) fn received(&mut self, stream: MediaStreamId, bytes: usize) {
        if self.stream == Some(stream) {
            self.window.bytes += bytes;
            self.window.frames += 1;
        }
    }

    pub(super) fn host_stats(&mut self, stats: &MediaControl) {
        if self.stream.is_some_and(|stream| stats.session_id == Some(stream.session_id)) {
            if stats.encode_idle != Some(true) {
                self.window.encode_ms = stats.encode_milliseconds;
            }
            if let Some(delivery_ms) = stats.delivery_milliseconds {
                self.window.delivery_ms = Some(self.window.delivery_ms.map_or(delivery_ms, |value| value.max(delivery_ms)));
            }
        }
    }

    pub(super) fn control_round_trip(&mut self, milliseconds: f64, now: Instant) {
        if self.stream.is_some() && milliseconds.is_finite() && milliseconds > 0.0 {
            self.control_rtt_ms = Some((milliseconds, now));
        }
    }

    pub(super) fn repair_requested(&mut self, stream: MediaStreamId) {
        if self.stream == Some(stream) {
            self.window.repair = true;
        }
    }

    pub(super) fn choose(&mut self, megabits: i64, now: Instant) {
        self.policy.choose(megabits, now);
        self.window = Window::default();
        self.started = now;
    }

    pub(super) fn confirm(&mut self, requested: i64, previous: i64, applied: i64, automatic: bool, succeeded: bool, now: Instant) {
        self.policy.confirm(requested, previous, applied, automatic, succeeded, now);
        self.window = Window::default();
        self.started = now;
    }

    pub(super) fn sample(&mut self, settings: StreamSettings, udp_rtt: Option<Duration>, ready_to_request: bool, now: Instant) -> Option<i64> {
        let started = self.started;
        let duration = now - started;
        self.started = now;
        let measured = std::mem::take(&mut self.window);
        let control_rtt = self.control_rtt_ms.take().filter(|&(_, at)| at >= started).map(|(value, _)| value);
        let rtt_ms = udp_rtt.map(|time| time.as_secs_f64() * 1_000.0).or(control_rtt);
        let rtt_growth_ms = rtt_ms.map(|rtt| {
            let floor = self.rtt_floor_ms.get_or_insert((rtt, now));
            if rtt < floor.0 || now - floor.1 > Duration::from_secs(30) {
                *floor = (rtt, now);
            }
            (rtt - floor.0).max(0.0)
        });
        if !ready_to_request {
            self.policy.reset_evidence();
            return None;
        }
        let sample = Sample {
            duration,
            frames: measured.frames,
            megabits: measured.bytes as f64 * 0.000_008 / duration.as_secs_f64(),
            delivery_ms: measured.delivery_ms,
            rtt_growth_ms,
            encode_ms: measured.encode_ms,
            repair: measured.repair,
        };
        self.policy.suggest(settings, sample, now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn traffic(delivery_ms: Option<f64>, megabits: f64) -> Sample {
        Sample { duration: SAMPLE_WINDOW, frames: 40, megabits, delivery_ms, rtt_growth_ms: Some(5.0), encode_ms: None, repair: false }
    }

    #[test]
    fn cuts_after_sustained_delivery_delay_and_recovers_inside_the_chosen_ceiling() {
        let start = Instant::now();
        let mut policy = BitratePolicy::new(12, start);
        let at = |second| start + Duration::from_secs(second);
        let original = StreamSettings::new(1920, 60, 12);
        assert_eq!(policy.suggest(original, traffic(Some(190.0), 4.0), at(1)), None);
        assert_eq!(policy.suggest(original, traffic(Some(210.0), 4.0), at(2)), Some(5));
        policy.confirm(5, 12, 5, true, true, at(2));
        let reduced = StreamSettings { megabits: 5, ..original };
        for second in 3..10 {
            assert_eq!(policy.suggest(reduced, traffic(Some(12.0), 4.0), at(second)), None);
        }
        assert_eq!(policy.suggest(reduced, traffic(Some(12.0), 4.0), at(10)), Some(6));
        policy.confirm(6, 5, 6, true, true, at(10));
        let raised = StreamSettings { megabits: 6, ..original };
        assert_eq!(policy.suggest(raised, traffic(Some(600.0), 3.0), at(11)), Some(3));
        policy.confirm(3, 6, 3, true, true, at(11));
        assert_eq!(policy.recovery_hold, BASE_RECOVERY_HOLD * 2);
    }

    #[test]
    fn repairs_jitter_and_a_quiet_screen_do_not_lower_quality() {
        let start = Instant::now();
        let mut policy = BitratePolicy::new(12, start);
        let settings = StreamSettings::new(1920, 60, 12);
        for second in 1..20 {
            let mut sample = traffic(Some(35.0), 10.0);
            sample.repair = second % 2 == 1;
            sample.rtt_growth_ms = Some(if sample.repair { 15.0 } else { 120.0 });
            assert_eq!(policy.suggest(settings, sample, start + Duration::from_secs(second)), None);
        }
        let idle = Sample { duration: SAMPLE_WINDOW, frames: 0, megabits: 0.0, delivery_ms: Some(600.0), rtt_growth_ms: None, encode_ms: None, repair: true };
        assert_eq!(policy.suggest(settings, idle, start + Duration::from_secs(20)), None);
    }

    #[test]
    fn a_control_rtt_spike_only_counts_in_its_own_window() {
        let start = Instant::now();
        let peer = Uuid::new_v4();
        let stream = MediaStreamId { session_id: peer, transport_epoch: 1, codec_epoch: 1 };
        let settings = StreamSettings::new(1920, 60, 12);
        let mut quality = AdaptiveQuality::new(settings.megabits, start);
        quality.use_stream(Some((stream, MediaPath::Tcp)), start);

        for second in 1..=3 {
            let end = start + SAMPLE_WINDOW * second;
            for _ in 0..5 {
                quality.received(stream, 30_000);
            }
            quality.host_stats(&MediaControl::stats(peer, None, Some(85.0)));
            if second <= 2 {
                quality.control_round_trip(if second == 1 { 20.0 } else { 200.0 }, end - Duration::from_millis(100));
            }
            assert_eq!(quality.sample(settings, None, true, end), None);
        }
    }

    #[test]
    fn a_host_clamp_bounds_upgrades_and_a_new_route_discards_old_evidence() {
        let start = Instant::now();
        let mut quality = AdaptiveQuality::new(20, start);
        let peer = Uuid::new_v4();
        let a = MediaStreamId { session_id: peer, transport_epoch: 1, codec_epoch: 1 };
        let b = MediaStreamId { transport_epoch: 2, ..a };
        quality.use_stream(Some((a, MediaPath::Udp)), start);
        quality.received(a, 1_500_000);
        quality.host_stats(&MediaControl::stats(peer, None, Some(900.0)));
        let switched = start + SAMPLE_WINDOW;
        quality.policy.recovery_hold = BASE_RECOVERY_HOLD * 2;
        quality.use_stream(None, switched);
        assert_eq!(quality.deadline(), None);
        quality.use_stream(Some((b, MediaPath::Udp)), switched);
        assert_eq!(quality.policy.recovery_hold, BASE_RECOVERY_HOLD * 2);
        let current = StreamSettings::new(1920, 60, 12);
        assert_eq!(quality.sample(current, None, true, switched + SAMPLE_WINDOW), None);
        let c = MediaStreamId { transport_epoch: 3, ..b };
        quality.use_stream(Some((c, MediaPath::Tcp)), switched + SAMPLE_WINDOW);
        assert_eq!(quality.policy.recovery_hold, BASE_RECOVERY_HOLD);
        quality.confirm(20, 12, 12, false, true, switched + SAMPLE_WINDOW);
        for second in 2..=10 {
            let at = switched + SAMPLE_WINDOW * second;
            assert_eq!(quality.policy.suggest(current, traffic(Some(10.0), 11.0), at), None);
        }
        let now = switched + SAMPLE_WINDOW * 15;
        quality.choose(5, now);
        // An older automatic request may already be on the wire when the user makes a new choice.
        quality.confirm(12, 12, 12, true, true, now + SAMPLE_WINDOW);
        assert_eq!(quality.policy.ceiling, 5);
        assert_eq!(quality.policy.host_ceiling, Some(12));
    }
}
