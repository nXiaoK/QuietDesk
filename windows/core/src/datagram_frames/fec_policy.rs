use crate::media::FragmentFeatures;
use crate::media::fragment::{
    PAYLOAD,
    fec::{self, Protection},
};
use crate::messages::StreamSettings;
use std::collections::VecDeque;
use std::time::Duration;
use tokio::time::Instant;

#[derive(Default)]
pub(crate) struct LossHistory {
    last: Option<Instant>,
    missing: VecDeque<(Instant, usize)>,
}

impl LossHistory {
    pub(super) fn note_repair(&mut self, now: Instant, count: usize) {
        self.last = Some(now);
        if count != 0 {
            self.prune(now);
            if self.missing.len() < 128 {
                self.missing.push_back((now, count));
            }
        }
    }

    fn prune(&mut self, now: Instant) {
        while self.missing.front().is_some_and(|(seen, _)| now.duration_since(*seen) > Duration::from_secs(5)) {
            self.missing.pop_front();
        }
    }

    pub(super) fn protection(&mut self, features: FragmentFeatures, settings: StreamSettings, frame: FrameLoad, now: Instant) -> Option<Protection> {
        let count = frame.payload_bytes.div_ceil(PAYLOAD);
        let recent = self.last.is_some_and(|seen| now.duration_since(seen) <= Duration::from_secs(8));
        let long_rtt = frame.rtt >= Duration::from_millis(15);
        let bytes_per_second = settings.megabits as f64 * 125_000.0;
        let per_frame = bytes_per_second / settings.frames_per_second as f64;
        if features.block_limit == 0 {
            let max = if recent || long_rtt { fec::MAX_XOR_FRAGMENTS } else { 6 };
            let budget = per_frame * if recent || long_rtt { 1.0 } else { 0.85 };
            return (features.xor && !frame.key && frame.queued == 0 && (2..=max).contains(&count) && (frame.payload_bytes + PAYLOAD) as f64 <= budget)
                .then_some(Protection::Xor);
        }
        let backlog = frame.queued != 0;
        if !(2..=features.block_limit).contains(&count) || (backlog && (!recent || frame.queued as f64 > bytes_per_second * 0.1)) {
            return None;
        }
        self.prune(now);
        let missing: usize = self.missing.iter().map(|(_, n)| n).sum();
        let desired = if missing >= 6 {
            3
        } else if recent {
            2
        } else if frame.key || settings.frames_per_second >= 60 || long_rtt {
            1
        } else {
            return None;
        };
        let max = desired - u8::from(backlog);
        if frame.key {
            return Some(Protection::Block { parity_per_block: max.min(2) });
        }
        let budget = per_frame * if recent || long_rtt { 1.35 } else { 1.15 };
        (1..=max).rev().map(|parity_per_block| Protection::Block { parity_per_block }).find(|protection| {
            let total = frame.payload_bytes + fec::parity_shard_count(count, *protection) * PAYLOAD;
            (total as f64) <= budget || (recent && *protection == Protection::Block { parity_per_block: 1 })
        })
    }
}

#[derive(Clone, Copy)]
pub(super) struct FrameLoad {
    pub(super) key: bool,
    pub(super) payload_bytes: usize,
    pub(super) queued: usize,
    pub(super) rtt: Duration,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn quality(fps: i64, mbps: i64) -> StreamSettings {
        StreamSettings::new(1920, fps, mbps)
    }
    fn frame(parts: usize, key: bool) -> FrameLoad {
        FrameLoad { key, payload_bytes: PAYLOAD * parts, queued: 0, rtt: Duration::ZERO }
    }
    fn rows(rows: u8) -> Option<Protection> {
        Some(Protection::Block { parity_per_block: rows })
    }

    #[test]
    fn clean_paths_protect_block_idrs_and_only_budgeted_fast_or_long_rtt_predictions() {
        let now = Instant::now();
        let mut loss = LossHistory::default();
        let caps = FragmentFeatures { xor: true, block_limit: 256, ..Default::default() };
        let mut load = frame(12, false);
        assert!(loss.protection(caps, quality(30, 8), load, now).is_none());
        assert_eq!(loss.protection(caps, quality(60, 8), load, now), rows(1));
        assert!(loss.protection(caps, quality(60, 2), load, now).is_none());
        load.rtt = Duration::from_millis(15);
        assert_eq!(loss.protection(caps, quality(30, 8), load, now), rows(1));
        assert_eq!(loss.protection(caps, quality(30, 8), frame(256, true), now), rows(1));
        assert!(loss.protection(caps, quality(30, 8), frame(257, true), now).is_none());
        assert!(loss.protection(caps, quality(30, 8), FrameLoad { queued: 1, ..frame(4, true) }, now).is_none());
    }

    #[test]
    fn observed_missing_originals_raise_redundancy_but_respect_backlog_deadlines_and_keyframe_limits() {
        let now = Instant::now();
        let mut loss = LossHistory::default();
        let caps = FragmentFeatures { block_limit: 4096, ..Default::default() };
        let settings = quality(30, 8);
        let load = frame(8, false);
        loss.note_repair(now, 2);
        assert_eq!(loss.protection(caps, settings, load, now), rows(2));
        loss.note_repair(now, 4);
        assert_eq!(loss.protection(caps, settings, load, now), rows(3));
        assert_eq!(loss.protection(caps, settings, FrameLoad { key: true, ..load }, now), rows(2));
        assert_eq!(loss.protection(caps, settings, FrameLoad { queued: 1, ..load }, now), rows(2));
        assert!(loss.protection(caps, settings, FrameLoad { queued: 100_001, ..load }, now).is_none());
        assert_eq!(loss.protection(caps, settings, load, now + Duration::from_secs(6)), rows(2));
        assert!(loss.protection(caps, settings, load, now + Duration::from_secs(9)).is_none());
    }

    #[test]
    fn xor_only_uses_short_predictions_and_requires_room_for_the_whole_shard() {
        let now = Instant::now();
        let mut loss = LossHistory::default();
        let caps = FragmentFeatures { xor: true, ..Default::default() };
        let settings = quality(30, 8);
        assert!(loss.protection(caps, settings, frame(7, false), now).is_none());
        assert!(loss.protection(caps, settings, frame(2, true), now).is_none());
        assert!(loss.protection(caps, quality(30, 1), frame(5, false), now).is_none());
        assert_eq!(loss.protection(caps, settings, frame(6, false), now), Some(Protection::Xor));
        assert!(loss.protection(caps, settings, FrameLoad { queued: 1, ..frame(6, false) }, now).is_none());
        loss.note_repair(now, 0);
        assert_eq!(loss.protection(caps, settings, frame(8, false), now), Some(Protection::Xor));
        assert!(loss.protection(caps, settings, frame(9, false), now).is_none());
    }
}
