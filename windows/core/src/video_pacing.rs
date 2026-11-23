//! Byte-rate pacing for independent video streams and datagrams.
use std::time::Duration;
use tokio::time::Instant;

const SLICE: usize = 16 * 1024;
const BURST: usize = 64 * 1024;

pub(crate) struct ByteCredit {
    rate: f64,
    burst: f64,
    credit: f64,
    updated: Instant,
}

impl ByteCredit {
    pub fn new(rate: f64, burst: f64, now: Instant) -> Self {
        Self { rate, burst, credit: burst, updated: now }
    }

    pub fn duration(&self, bytes: usize) -> Duration {
        Duration::from_secs_f64(bytes as f64 / self.rate)
    }

    fn replenish(&mut self, now: Instant) {
        let elapsed = now.saturating_duration_since(self.updated);
        self.credit = (self.credit + elapsed.as_secs_f64() * self.rate).min(self.burst);
        self.updated = now.max(self.updated);
    }

    pub fn retarget(&mut self, rate: f64, burst: f64, now: Instant) {
        self.replenish(now);
        self.rate = rate;
        self.burst = burst;
        self.credit = self.credit.min(burst);
    }

    pub fn wait(&mut self, bytes: usize, now: Instant) -> Option<Duration> {
        self.replenish(now);
        (self.credit + 1.0 < bytes as f64).then(|| Duration::from_secs_f64((bytes as f64 - self.credit) / self.rate))
    }

    pub fn submitted(&mut self, bytes: usize) {
        self.credit = (self.credit - bytes as f64).max(0.0);
    }
}

pub(crate) struct VideoPacer(ByteCredit);

impl VideoPacer {
    fn rate(target: u32) -> f64 {
        (f64::from(target) * 2.5).clamp(40.0, 200.0) * 125_000.0
    }

    pub fn at(target: u32, now: Instant) -> Self {
        Self(ByteCredit::new(Self::rate(target), BURST as f64, now))
    }

    pub fn set_target(&mut self, target: u32, now: Instant) {
        self.0.retarget(Self::rate(target), BURST as f64, now);
    }

    pub fn duration(target: u32, bytes: usize) -> Duration {
        Duration::from_secs_f64(bytes as f64 / Self::rate(target))
    }

    fn next(&mut self, remaining: usize, now: Instant) -> Result<usize, Duration> {
        let slice = remaining.min(SLICE);
        if let Some(delay) = self.0.wait(slice, now) {
            return Err(delay);
        }
        self.0.submitted(slice);
        Ok(slice)
    }

    pub async fn write(&mut self, writer: &mut (impl tokio::io::AsyncWrite + Unpin), mut bytes: &[u8]) -> std::io::Result<()> {
        use tokio::io::AsyncWriteExt;
        while !bytes.is_empty() {
            match self.next(bytes.len(), Instant::now()) {
                Ok(length) => {
                    writer.write_all(&bytes[..length]).await?;
                    bytes = &bytes[length..];
                }
                Err(delay) => tokio::time::sleep(delay).await,
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn changing_the_tcp_target_does_not_mint_a_second_burst() {
        let now = Instant::now();
        let mut pacing = VideoPacer::at(50, now);
        for _ in 0..BURST / SLICE {
            assert_eq!(pacing.next(BURST, now), Ok(SLICE));
        }
        pacing.set_target(5, now);
        assert_eq!(pacing.next(BURST, now), Err(VideoPacer::duration(5, SLICE)));
    }

    #[test]
    fn limits_rate_burst_and_slices_across_frame_boundaries() {
        let now = Instant::now();
        for (target, rate) in [(1, 5_000_000.0), (40, 12_500_000.0), (120, 25_000_000.0)] {
            let mut pacing = VideoPacer::at(target, now);
            for _ in 0..4 {
                assert_eq!(pacing.next(BURST * 2, now), Ok(SLICE));
            }
            pacing.set_target(target, now);
            let wait = Duration::from_secs_f64(SLICE as f64 / rate);
            assert_eq!(pacing.next(SLICE, now), Err(wait));
            assert_eq!(pacing.next(SLICE, now + wait), Ok(SLICE));
            let later = now + Duration::from_secs(2);
            assert_eq!(pacing.next(1024, later), Ok(1024));
            for _ in 0..3 {
                assert_eq!(pacing.next(SLICE, later), Ok(SLICE));
            }
            assert_eq!(pacing.next(SLICE - 1024, later), Ok(SLICE - 1024));
            assert!(pacing.next(2, later).is_err());
        }
    }
}
