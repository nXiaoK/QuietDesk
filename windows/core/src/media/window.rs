//! Negotiated capture credits and the encoded-byte budget shared by the video queues.
use super::MediaControl;
use std::time::Duration;
use tokio::time::Instant;

pub const LEGACY_FRAMES: usize = 3;
pub const STATIC_FRAMES: usize = 6;
pub const MAX_DYNAMIC_FRAMES: usize = 24;
pub const MAX_BUFFERED_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Copy, Default)]
pub(crate) struct CaptureLimits {
    pub dynamic: bool,
    advertised: Option<usize>,
}

impl CaptureLimits {
    pub fn from_request(request: &MediaControl) -> Self {
        Self {
            dynamic: request.dynamic_frame_window == Some(true),
            advertised: request.receive_frame_window.map(|value| value.clamp(1, STATIC_FRAMES as i64) as usize),
        }
    }

    pub fn credits(self, fps: i64, rtt: Option<Duration>) -> usize {
        if !self.dynamic {
            return self.advertised.map_or(LEGACY_FRAMES, |value| value.min(if fps >= 60 { STATIC_FRAMES } else { 4 }));
        }
        let fps = fps.clamp(1, 240);
        let baseline = if fps > 60 {
            8
        } else if fps == 60 {
            STATIC_FRAMES
        } else {
            4
        };
        let seconds = rtt.unwrap_or_default().as_secs_f64().min(1.0);
        baseline.max((fps as f64 * seconds * 1.5).ceil() as usize + 3).min(MAX_DYNAMIC_FRAMES)
    }
}

#[derive(Default)]
pub(crate) struct RoundTrips {
    control: Option<(Instant, Duration)>,
    udp: Option<Duration>,
}

impl RoundTrips {
    pub fn record_control(&mut self, now: Instant, milliseconds: f64) {
        if let Ok(duration) = Duration::try_from_secs_f64(milliseconds / 1000.0)
            && !duration.is_zero()
        {
            self.control = Some((now, duration));
        }
    }

    pub fn effective(&mut self, now: Instant, active_udp: bool, measured_udp: Option<Duration>) -> Option<Duration> {
        if let Some(measurement) = measured_udp {
            self.udp = Some(measurement);
        }
        let ctrl = self.control.filter(|(at, _)| now.duration_since(*at) <= Duration::from_secs(15)).map(|(_, value)| value);
        if active_udp { ctrl.max(self.udp) } else { ctrl.or(self.udp) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_credits_follow_the_first_request_and_measured_round_trip() {
        let mut request = crate::media::ViewerMedia::request();
        assert_eq!(CaptureLimits::from_request(&request).credits(60, None), 3);
        request.receive_frame_window = Some(i64::MAX);
        let fixed = CaptureLimits::from_request(&request);
        assert_eq!((fixed.credits(30, None), fixed.credits(60, Some(Duration::from_secs(1)))), (4, 6));
        request.dynamic_frame_window = Some(true);
        let dynamic = CaptureLimits::from_request(&request);
        for (fps, ms, expected) in [(30, 0, 4), (60, 0, 6), (120, 0, 8), (60, 50, 8), (60, 200, 21), (60, 250, 24), (240, 2000, 24)] {
            assert_eq!(dynamic.credits(fps, Some(Duration::from_millis(ms))), expected);
        }
    }

    #[test]
    fn only_recent_control_measurements_and_observed_datagram_round_trips_set_the_target() {
        let now = Instant::now();
        let mut rtt = RoundTrips::default();
        assert_eq!(rtt.effective(now, true, None), None);
        rtt.record_control(now, 100.0);
        let udp = Duration::from_millis(150);
        assert_eq!(rtt.effective(now, true, Some(udp)), Some(udp));
        assert_eq!(rtt.effective(now, false, None), Some(Duration::from_millis(100)));
        rtt.record_control(now, f64::NAN);
        assert_eq!(rtt.effective(now + Duration::from_secs(16), false, None), Some(udp));
    }
}
