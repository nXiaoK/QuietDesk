//! Schedules original fragments, period-limited repairs and negotiated parity for one video epoch.
mod fec_policy;

use crate::datagram_path::DatagramPath;
use crate::error::{DeskError, Result};
use crate::media::fragment::fec::{self, ParityBlock};
use crate::media::fragment::{BYTE_BUDGET, MAX_RECORD_BYTES, OutgoingFragment, PAYLOAD, RepairCache, SendEvent};
use crate::media::{FeedbackKind, FragmentFeatures, MediaFeedback, MediaFrame, MediaFrameHeader, MediaStreamId};
use crate::messages::StreamSettings;
use crate::video_pacing::ByteCredit;
use fec_policy::FrameLoad;
pub(crate) use fec_policy::LossHistory;
use std::collections::VecDeque;
use std::time::Duration;
use tokio::time::Instant;

enum Pending {
    Fragment { fragment: OutgoingFragment, repair: bool },
    Block { header: MediaFrameHeader, block: ParityBlock, bytes: usize },
    Parity { header: MediaFrameHeader, datagram: Vec<u8> },
}

impl Pending {
    fn header(&self) -> MediaFrameHeader {
        match self {
            Self::Fragment { fragment, .. } => fragment.header(),
            Self::Block { header, .. } | Self::Parity { header, .. } => *header,
        }
    }

    fn bytes(&self) -> usize {
        match self {
            Self::Fragment { fragment, .. } => fragment.wire_len(),
            Self::Block { bytes, .. } => *bytes,
            Self::Parity { datagram, .. } => datagram.len(),
        }
    }
}

pub(crate) struct DatagramFrames {
    pub stream: MediaStreamId,
    cache: RepairCache,
    pending: VecDeque<Pending>,
    pending_bytes: usize,
    pacing: ByteCredit,
    // Frames queued under the previous setting keep their submission deadlines.
    pace_change_after: Option<u64>,
    next_send: Instant,
    next_poll: Instant,
    settings: StreamSettings,
    features: FragmentFeatures,
    loss: LossHistory,
}

impl DatagramFrames {
    fn pacing_limits(megabits: i64) -> (f64, f64) {
        let rate = (megabits as f64 * 200_000.0).max(250_000.0);
        let burst = (rate * 0.008).clamp(((MAX_RECORD_BYTES + 1) * 4) as f64, 32_768.0);
        (rate, burst)
    }

    pub fn new(stream: MediaStreamId, settings: StreamSettings, features: FragmentFeatures, now: Instant, loss: LossHistory) -> Self {
        let settings = StreamSettings { megabits: settings.megabits.max(1), frames_per_second: settings.frames_per_second.max(1), ..settings };
        let (rate, burst) = Self::pacing_limits(settings.megabits);
        Self {
            pacing: ByteCredit::new(rate, burst, now),
            pace_change_after: None,
            stream,
            cache: RepairCache::new(stream),
            pending: VecDeque::new(),
            pending_bytes: 0,
            next_send: now,
            next_poll: now,
            settings,
            features,
            loss,
        }
    }

    pub fn into_loss_history(self) -> LossHistory {
        self.loss
    }

    pub fn set_capacity(&mut self, capacity: usize) {
        self.cache.set_capacity(capacity);
    }

    pub fn set_bitrate(&mut self, megabits: i64, now: Instant) {
        self.settings.megabits = megabits;
        self.pace_change_after = self.pending.back().map(|item| item.header().frame_id);
        if self.pace_change_after.is_none() {
            let (rate, burst) = Self::pacing_limits(megabits);
            self.pacing.retarget(rate, burst, now);
            self.next_send = now;
        }
    }

    pub fn insert(&mut self, frame: MediaFrame, now: Instant, rtt: Duration) -> Result<Duration> {
        let header = frame.header;
        let load = FrameLoad { key: header.is_idr, payload_bytes: frame.packet.encoded_len(), queued: self.pending_bytes, rtt };
        let protection = self.loss.protection(self.features, self.settings, load, now);
        let count = load.payload_bytes.div_ceil(PAYLOAD);
        let originals = load.payload_bytes + count * (MAX_RECORD_BYTES + 1 - PAYLOAD);
        let shard_bytes = protection.map_or(0, fec::Protection::wire_len);
        let parity = protection.map_or(0, |mode| fec::parity_shard_count(count, mode) * shard_bytes);
        let bytes = originals + parity;
        if bytes > BYTE_BUDGET - self.pending_bytes {
            return Err(DeskError::invalid("媒体数据报发送队列已满"));
        }
        let rate = Self::pacing_limits(self.settings.megabits).0;
        let serialization = Duration::from_secs_f64(bytes as f64 / rate);
        let wire_time = self.pacing.duration(self.pending_bytes).max(Duration::from_secs_f64(self.pending_bytes as f64 / rate)) + serialization;
        let minimum = if header.is_idr { Duration::from_secs(1) } else { Duration::from_millis(250) };
        let ttl = (wire_time + rtt * 3 + Duration::from_millis(80)).clamp(minimum, Duration::from_secs(5));
        let fragments = self.cache.insert(&frame, now, now + ttl)?;
        let mut blocks = match protection {
            Some(mode) => fec::plan(&fragments, mode)?,
            None => Vec::new(),
        }
        .into_iter()
        .peekable();
        for fragment in fragments {
            let index = fragment.index();
            self.pending.push_back(Pending::Fragment { fragment, repair: false });
            if let Some(block) = blocks.next_if(|block| block.after_index() == index) {
                self.pending.push_back(Pending::Block { header, bytes: block.shard_count() * shard_bytes, block });
            }
        }
        self.pending_bytes += bytes;
        Ok(serialization)
    }

    pub fn deadline(&self) -> Instant {
        if self.pending.is_empty() { self.next_poll } else { self.next_send.min(self.next_poll) }
    }

    fn update(&mut self, event: Option<SendEvent>, now: Instant, tail_probe: bool) -> bool {
        match event {
            Some(SendEvent::Expired(_)) => return false,
            Some(SendEvent::Repair(fragments)) => {
                let bytes: usize = fragments.iter().map(OutgoingFragment::wire_len).sum();
                if bytes > BYTE_BUDGET - self.pending_bytes {
                    return false;
                }
                self.loss.note_repair(now, if tail_probe { 0 } else { fragments.len() });
                self.pending_bytes += bytes;
                for fragment in fragments.into_iter().rev() {
                    self.pending.push_front(Pending::Fragment { fragment, repair: true });
                }
            }
            None => {}
        }
        true
    }

    pub fn fully_submitted(&self, header: MediaFrameHeader) -> bool {
        self.stream == header.stream && self.cache.fully_submitted(header)
    }

    pub fn needed_no_repair(&self, header: MediaFrameHeader) -> bool {
        self.cache.needed_no_repair(header)
    }

    pub fn feedback(&mut self, feedback: &MediaFeedback, now: Instant, rtt: Duration) -> bool {
        if feedback.header.stream != self.stream {
            return true;
        }
        let event = self.cache.feedback(feedback, now, rtt);
        if matches!(feedback.kind, FeedbackKind::Decoded | FeedbackKind::Reassembled) {
            self.pending.retain(|pending| {
                let keep = self.cache.needs_fragments(pending.header());
                if !keep {
                    self.pending_bytes -= pending.bytes();
                }
                keep
            });
        }
        self.update(event, now, false)
    }

    pub fn pump(&mut self, path: &DatagramPath, now: Instant) -> bool {
        if now >= self.next_poll {
            self.next_poll = now + Duration::from_millis(20);
            let event = self.cache.poll(now, path.rtt());
            if !self.update(event, now, true) {
                return false;
            }
        }
        if now < self.next_send {
            return true;
        }
        self.send_batch(now, |datagram| path.send(datagram));
        true
    }

    fn send_batch(&mut self, now: Instant, mut send: impl FnMut(Vec<u8>) -> bool) {
        let mut encoded_block = false;
        self.next_send = now;
        // Yield to control between bursts; a large key frame computes at most one group per turn.
        loop {
            if !encoded_block && let Some(Pending::Block { header, block, .. }) = self.pending.pop_front_if(|item| matches!(item, Pending::Block { .. })) {
                for shard in block.encode().into_iter().rev() {
                    self.pending.push_front(Pending::Parity { header, datagram: shard.datagram() });
                }
                encoded_block = true;
            }
            let Some(pending) = self.pending.front() else { break };
            if self.pace_change_after.is_some_and(|previous| pending.header().frame_id > previous) {
                self.pace_change_after = None;
                let (rate, burst) = Self::pacing_limits(self.settings.megabits);
                self.pacing.retarget(rate, burst, now);
            }
            if matches!(pending, Pending::Block { .. }) {
                self.next_send = now + Duration::from_micros(200);
                break;
            }
            let size = pending.bytes();
            if let Some(delay) = self.pacing.wait(size, now) {
                self.next_send = now + delay.max(Duration::from_micros(200));
                break;
            }
            let datagram = match pending {
                Pending::Fragment { fragment, repair } => {
                    let mut datagram = Vec::with_capacity(fragment.wire_len());
                    datagram.push(if *repair && self.features.marked_repairs { 5 } else { 3 });
                    datagram.extend_from_slice(&fragment.record());
                    datagram
                }
                Pending::Parity { datagram, .. } => datagram.clone(),
                Pending::Block { .. } => unreachable!("handled before submitting parity"),
            };
            if !send(datagram) {
                self.next_send = now + Duration::from_millis(1);
                break;
            }
            if let Pending::Fragment { fragment, repair: false } = pending {
                self.cache.submitted(fragment.header(), fragment.index(), now);
            }
            self.pending.pop_front();
            self.pending_bytes -= size;
            self.pacing.submitted(size);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::FragmentRange;
    use crate::video::{EncodedFrame, VideoPacket};
    use uuid::Uuid;

    #[test]
    fn bitrate_change_paces_new_frames_without_delaying_already_queued_originals() {
        let now = Instant::now();
        let stream = MediaStreamId { session_id: Uuid::new_v4(), transport_epoch: 1, codec_epoch: 1 };
        let mut queue = DatagramFrames::new(stream, StreamSettings::new(1920, 60, 12), FragmentFeatures::default(), now, LossHistory::default());
        let frame = |id, nal, sps, pps| {
            let mut avcc = 8_400_u32.to_be_bytes().to_vec();
            avcc.push(nal);
            avcc.resize(8_404, 1);
            let packet = VideoPacket::h264(id as u32, EncodedFrame { avcc, sps, pps });
            MediaFrame::new(stream, id, packet).unwrap()
        };
        let old = frame(1, 0x65, vec![0x67], vec![0x68]);
        let next = frame(2, 0x41, vec![], vec![]);
        let (old_header, next_header) = (old.header, next.header);
        let old_serialization = queue.insert(old, now, Duration::ZERO).unwrap();
        queue.set_bitrate(1, now);
        let next_serialization = queue.insert(next, now, Duration::ZERO).unwrap();
        assert!(next_serialization > old_serialization * 8);
        queue.send_batch(now, |_| true);
        assert!(queue.fully_submitted(old_header));
        assert!(!queue.fully_submitted(next_header));
        while !queue.pending.is_empty() {
            queue.send_batch(queue.next_send, |_| true);
        }
        assert!(queue.fully_submitted(next_header));
    }

    #[test]
    fn a_full_socket_retries_originals_and_only_accepted_fragments_can_be_acknowledged() {
        let stream = MediaStreamId { session_id: Uuid::new_v4(), transport_epoch: 1, codec_epoch: 1 };
        let now = Instant::now();
        let mut avcc = 8_400_u32.to_be_bytes().to_vec();
        avcc.push(0x65);
        avcc.resize(8_404, 1);
        let packet = VideoPacket::h264(1, EncodedFrame { avcc, sps: vec![0x67], pps: vec![0x68] });
        let frame = MediaFrame::new(stream, 1, packet).unwrap();
        let header = frame.header;
        for marked in [true, false] {
            let mut queue = DatagramFrames::new(
                stream,
                StreamSettings::new(1920, 30, 1),
                FragmentFeatures { marked_repairs: marked, ..FragmentFeatures::default() },
                now,
                LossHistory::default(),
            );
            queue.insert(frame.clone(), now, Duration::ZERO).unwrap();
            let total = queue.pending.len();
            queue.send_batch(now, |_| false);
            assert_eq!(queue.pending.len(), total);
            assert_eq!(queue.next_send, now + Duration::from_millis(1));
            queue.send_batch(now, |d| d[0] == 3);
            assert_eq!(queue.pending.len(), total - 4);
            assert!(queue.next_send >= now + Duration::from_millis(4));
            let ack = MediaFeedback::new(FeedbackKind::Decoded, header).unwrap();
            assert!(queue.feedback(&ack, now, Duration::ZERO));
            assert_eq!(queue.pending.len(), total - 4);
            assert!(!queue.fully_submitted(header));
            while !queue.pending.is_empty() {
                queue.send_batch(queue.next_send, |_| true);
            }
            assert!(queue.fully_submitted(header));
            let later = now + Duration::from_millis(40);
            let nack = MediaFeedback::nack(header, vec![FragmentRange { first: 2, count: 1 }]).unwrap();
            assert!(queue.feedback(&nack, later, Duration::ZERO));
            let mut repair = Vec::new();
            queue.send_batch(later, |d| {
                repair.push(d);
                true
            });
            assert_eq!(repair.len(), 1);
            assert_eq!(repair[0][0], if marked { 5 } else { 3 });
            assert!(queue.feedback(&ack, later, Duration::ZERO));
            assert!(queue.pending.is_empty());
        }
    }

    #[test]
    fn parity_is_paced_after_its_own_block_and_never_acknowledges_an_original() {
        let stream = MediaStreamId { session_id: Uuid::new_v4(), transport_epoch: 1, codec_epoch: 1 };
        let settings = StreamSettings::new(1920, 60, 8);
        let features = FragmentFeatures { marked_repairs: true, xor: true, block_limit: 4096 };
        let now = Instant::now();
        let mut queue = DatagramFrames::new(stream, settings, features, now, LossHistory::default());
        let size: usize = 14 * PAYLOAD - 200;
        let mut avcc = (size as u32).to_be_bytes().to_vec();
        avcc.push(0x65);
        avcc.resize(4 + size, 1);
        let f = MediaFrame::new(stream, 1, VideoPacket::h264(1, EncodedFrame { avcc, sps: vec![0x67], pps: vec![0x68] })).unwrap();
        let header = f.header;
        let original_bytes = f.packet.encoded_len() + 14 * (MAX_RECORD_BYTES + 1 - PAYLOAD);
        queue.insert(f, now, Duration::ZERO).unwrap();
        let shard_bytes = fec::Protection::Block { parity_per_block: 1 }.wire_len();
        assert_eq!(queue.pending_bytes, original_bytes + 2 * shard_bytes);
        let mut wire = Vec::new();
        queue.send_batch(now, |d| {
            if d[0] != 10 {
                wire.push(d);
                true
            } else {
                false
            }
        });
        assert_eq!(wire.len(), 7);
        assert!(!queue.fully_submitted(header));
        let remaining = queue.pending_bytes;
        queue.send_batch(queue.next_send, |d| {
            assert_eq!(d[0], 10);
            false
        });
        assert_eq!(queue.pending_bytes, remaining);
        let mut reject_last = false;
        while !queue.fully_submitted(header) {
            queue.send_batch(queue.next_send, |d| {
                if reject_last && d[0] == 10 {
                    return false;
                }
                reject_last |= d[0] == 10;
                wire.push(d);
                true
            });
        }
        assert!(queue.fully_submitted(header));
        assert_eq!(wire.iter().map(|r| r[0]).collect::<Vec<_>>(), [vec![3; 7], vec![10], vec![3; 7]].concat());
        assert_eq!(wire[7].len(), shard_bytes);
        assert_eq!(queue.pending_bytes, shard_bytes);
        let received = MediaFeedback::new(FeedbackKind::Reassembled, header).unwrap();
        assert!(queue.feedback(&received, now, Duration::ZERO));
        assert_eq!(queue.pending_bytes, 0);
        assert!(queue.pending.is_empty());
    }
}
