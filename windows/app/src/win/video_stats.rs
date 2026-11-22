//! Per-window measurements on the active capture thread. CPU time includes all threads in the process.

use quietdesk_core::host::FrameSubmission;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::FILETIME;
use windows::Win32::System::Threading::{GetCurrentProcess, GetProcessTimes};

fn process_cpu_ticks() -> Option<u64> {
    let (mut created, mut exited, mut kernel, mut user) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
    unsafe {
        GetProcessTimes(GetCurrentProcess(), &mut created, &mut exited, &mut kernel, &mut user).ok()?;
    }
    let ticks = |t: FILETIME| (u64::from(t.dwHighDateTime) << 32) | u64::from(t.dwLowDateTime);
    ticks(user).checked_add(ticks(kernel))
}

fn cpu_ms_per_second(start: Option<u64>, end: Option<u64>, window: Duration) -> Option<f64> {
    let ticks = end?.checked_sub(start?)?;
    Some(ticks as f64 / 10_000.0 / window.as_secs_f64())
}

fn decimal(value: Option<f64>) -> String {
    value.map_or_else(|| "na".into(), |v| format!("{v:.3}"))
}

#[derive(Default)]
pub(super) struct Stage {
    calls: u64,
    elapsed: Duration,
}

impl Stage {
    pub(super) fn record(&mut self, elapsed: Duration) {
        self.calls += 1;
        self.elapsed += elapsed;
    }

    fn avg_ms(&self) -> Option<f64> {
        mean_ms(self.elapsed, self.calls)
    }
}

fn mean_ms(total: Duration, samples: u64) -> Option<f64> {
    (samples != 0).then(|| total.as_secs_f64() * 1000.0 / samples as f64)
}

pub(super) struct VideoStats {
    started: Instant,
    cpu: Option<u64>,
    source: &'static str,
    capture: Stage,
    waited: Duration,
    changed: u64,
    pub(super) convert: Stage,
    encode: Stage,
    repeats: u64,
    queued: u64,
    dropped: u64,
}

impl VideoStats {
    pub(super) fn new(now: Instant, source: &'static str) -> Self {
        Self::start(now, source, process_cpu_ticks())
    }

    fn start(now: Instant, source: &'static str, cpu: Option<u64>) -> Self {
        Self {
            started: now,
            cpu,
            source,
            capture: Stage::default(),
            waited: Duration::ZERO,
            changed: 0,
            convert: Stage::default(),
            encode: Stage::default(),
            repeats: 0,
            queued: 0,
            dropped: 0,
        }
    }

    pub(super) fn captured(&mut self, source: &'static str, elapsed: Duration, waited: Duration, changed: bool) {
        if source != self.source {
            self.source = "mixed";
        }
        self.capture.record(elapsed);
        self.waited += waited;
        self.changed += u64::from(changed);
    }

    pub(super) fn encoded(&mut self, elapsed: Duration, repeat: bool) {
        self.encode.record(elapsed);
        self.repeats += u64::from(repeat);
    }

    pub(super) fn output(&mut self, submission: FrameSubmission) {
        match submission {
            FrameSubmission::Queued => self.queued += 1,
            FrameSubmission::Dropped | FrameSubmission::Closed => self.dropped += 1,
        }
    }

    pub(super) fn report_if_due(&mut self, now: Instant, source: &'static str) {
        let window = now.duration_since(self.started);
        if window < Duration::from_secs(1) {
            return;
        }
        let cpu = process_cpu_ticks();
        log::info!(
            "host video stats window_ms={} source={} capture_calls={} changed={} convert_calls={} encode_calls={} repeats={} output={} queued={} dropped={} capture_avg_ms={} capture_wait_avg_ms={} capture_work_avg_ms={} convert_avg_ms={} encode_avg_ms={} process_cpu_ms_per_s={}",
            window.as_millis(),
            self.source,
            self.capture.calls,
            self.changed,
            self.convert.calls,
            self.encode.calls,
            self.repeats,
            self.queued + self.dropped,
            self.queued,
            self.dropped,
            decimal(self.capture.avg_ms()),
            decimal(mean_ms(self.waited, self.capture.calls)),
            decimal(mean_ms(self.capture.elapsed.saturating_sub(self.waited), self.capture.calls)),
            decimal(self.convert.avg_ms()),
            decimal(self.encode.avg_ms()),
            decimal(cpu_ms_per_second(self.cpu, cpu, window)),
        );
        *self = Self::start(now, source, cpu);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_wait_stage_denominators_and_discard_accounting_are_independent() {
        let mut stats = VideoStats::start(Instant::now(), "dxgi", None);
        assert_eq!(stats.capture.avg_ms(), None);
        stats.captured("dxgi", Duration::from_millis(10), Duration::from_millis(7), false);
        stats.captured("gdi", Duration::from_millis(6), Duration::from_millis(3), true);
        stats.convert.record(Duration::from_millis(4));
        stats.encoded(Duration::from_millis(8), false);
        stats.encoded(Duration::from_millis(2), true);
        stats.output(FrameSubmission::Queued);
        stats.output(FrameSubmission::Dropped);
        stats.output(FrameSubmission::Closed);
        assert_eq!(stats.source, "mixed");
        assert_eq!(stats.capture.avg_ms(), Some(8.0));
        assert_eq!(mean_ms(stats.waited, stats.capture.calls), Some(5.0));
        assert_eq!(mean_ms(stats.capture.elapsed - stats.waited, stats.capture.calls), Some(3.0));
        assert_eq!((stats.convert.avg_ms(), stats.encode.avg_ms()), (Some(4.0), Some(5.0)));
        assert_eq!((stats.changed, stats.repeats, stats.queued, stats.dropped), (1, 1, 1, 2));
    }

    #[test]
    fn process_cpu_uses_actual_wall_time_and_preserves_unavailable_samples() {
        let elapsed = Duration::from_secs(2);
        assert_eq!(cpu_ms_per_second(Some(100), Some(30_000_100), elapsed), Some(1500.0));
        assert_eq!(cpu_ms_per_second(Some(100), None, elapsed), None);
        assert_eq!(cpu_ms_per_second(Some(100), Some(99), elapsed), None);
    }
}
