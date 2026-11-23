use super::*;
use crate::media::FeedbackKind;
use std::collections::BTreeMap;
use tokio::time::Instant;

#[derive(Debug)]
pub enum SendEvent {
    Repair(Vec<OutgoingFragment>),
    Expired(MediaFrameHeader),
}

struct Cached {
    header: MediaFrameHeader,
    bytes: Arc<[u8]>,
    base: u64,
    count: u16,
    submitted: u16,
    sent_at: Option<Instant>,
    last_repair: Option<Instant>,
    rounds: u8,
    probes: u8,
    probe_at: Option<Instant>,
    heard: bool,
    reassembled: bool,
    deadline: Instant,
}

impl Cached {
    fn fragment(&self, index: u16) -> OutgoingFragment {
        OutgoingFragment { header: self.header, index, sequence: self.base + u64::from(index), frame: self.bytes.clone() }
    }
    fn cost(&self) -> usize {
        self.bytes.len() + usize::from(self.count) * FRAGMENT_HEADER
    }
    fn time_to_repair(&self, now: Instant, rtt: Duration) -> bool {
        self.deadline.saturating_duration_since(now) > rtt.saturating_add(Duration::from_millis(5))
    }
}

pub struct RepairCache {
    capacity: usize,
    stream: MediaStreamId,
    frames: BTreeMap<u64, Cached>,
    next_frame: u64,
    next_packet: u64,
    opener_submitted: bool,
    buffered: usize,
    failed: bool,
}

impl RepairCache {
    pub fn new(stream: MediaStreamId) -> Self {
        Self { capacity: STATIC_FRAMES, stream, frames: BTreeMap::new(), next_frame: 1, next_packet: 1, opener_submitted: false, buffered: 0, failed: false }
    }

    pub(crate) fn set_capacity(&mut self, capacity: usize) {
        self.capacity = capacity;
    }

    pub fn insert(&mut self, frame: &MediaFrame, now: Instant, deadline: Instant) -> Result<Vec<OutgoingFragment>> {
        let h = frame.header;
        if self.failed
            || h.stream != self.stream
            || h.frame_id != self.next_frame
            || h.frame_id == u64::MAX
            || (h.frame_id == 1 && !h.is_idr)
            || deadline <= now
        {
            return Err(DeskError::invalid("媒体帧顺序、恢复屏障或截止时间无效"));
        }
        let bytes = frame.packet.encode()?;
        if bytes.len() > MediaFrame::MAXIMUM_PACKET_BYTES {
            return Err(DeskError::invalid("媒体帧超过缓存上限"));
        }
        let count = bytes.len().div_ceil(PAYLOAD) as u16;
        let cost = bytes.len() + usize::from(count) * FRAGMENT_HEADER;
        if self.frames.len() >= self.capacity || cost > BYTE_BUDGET - self.buffered {
            return Err(DeskError::invalid("媒体发送窗口或缓存已满"));
        }
        let base = self.next_packet;
        self.next_packet = base.checked_add(u64::from(count)).ok_or_else(|| DeskError::invalid("媒体包序号已用尽"))?;
        let cached = Cached {
            header: h,
            bytes: bytes.into(),
            base,
            count,
            submitted: 0,
            sent_at: None,
            last_repair: None,
            rounds: 0,
            probes: 0,
            probe_at: None,
            heard: false,
            reassembled: false,
            deadline,
        };
        let first_send = (0..count).map(|i| cached.fragment(i)).collect();
        self.frames.insert(self.next_frame, cached);
        self.next_frame += 1;
        self.buffered += cost;
        Ok(first_send)
    }

    /// Pending originals and repairs become unnecessary after arrival or cumulative decode.
    pub fn needs_fragments(&self, header: MediaFrameHeader) -> bool {
        self.frames.get(&header.frame_id).is_some_and(|cached| cached.header == header && !cached.reassembled)
    }

    /// The reliable decodedReady may arrive after a datagram ACK has already retired the opening IDR.
    pub fn fully_submitted(&self, header: MediaFrameHeader) -> bool {
        if self.failed || header.stream != self.stream {
            return false;
        }
        if header.frame_id == 1 {
            return header.is_idr && self.opener_submitted;
        }
        self.frames.get(&header.frame_id).is_some_and(|cached| cached.header == header && cached.submitted == cached.count)
    }

    pub(crate) fn needed_no_repair(&self, header: MediaFrameHeader) -> bool {
        self.frames.get(&header.frame_id).is_some_and(|cached| cached.header == header && cached.rounds == 0 && cached.probes == 0)
    }

    pub fn submitted(&mut self, header: MediaFrameHeader, index: u16, now: Instant) {
        if let Some(c) = self.frames.get_mut(&header.frame_id)
            && c.header == header
            && index == c.submitted
            && index < c.count
        {
            c.submitted += 1;
            if c.submitted == c.count {
                if header.frame_id == 1 {
                    self.opener_submitted = true;
                }
                c.sent_at = Some(now);
            }
        }
    }

    fn fail(&mut self, h: MediaFrameHeader) -> Option<SendEvent> {
        self.failed = true;
        self.frames.clear();
        self.buffered = 0;
        Some(SendEvent::Expired(h))
    }

    fn expired(&self, now: Instant) -> Option<MediaFrameHeader> {
        self.frames.values().find(|c| now >= c.deadline).map(|c| c.header)
    }

    pub fn feedback(&mut self, feedback: &MediaFeedback, now: Instant, rtt: Duration) -> Option<SendEvent> {
        if self.failed || self.stream != feedback.header.stream {
            return None;
        }
        if let Some(h) = self.expired(now) {
            return self.fail(h);
        }
        let id = feedback.header.frame_id;
        let c = self.frames.get_mut(&id)?;
        if matches!(feedback.kind, FeedbackKind::Decoded | FeedbackKind::Reassembled) && (c.header != feedback.header || c.submitted < c.count) {
            return None;
        }
        match feedback.kind {
            FeedbackKind::Decoded => {
                while self.frames.first_key_value().is_some_and(|(&first, _)| first <= id) {
                    let (_, frame) = self.frames.pop_first().unwrap();
                    self.buffered -= frame.cost();
                }
            }
            FeedbackKind::Expired => {
                let header = c.header;
                return self.fail(header);
            }
            FeedbackKind::Reassembled => {
                c.heard = true;
                if !c.reassembled {
                    c.reassembled = true;
                    c.deadline = c.deadline.max(now + DECODE_TIMEOUT);
                }
            }
            FeedbackKind::Nack => {
                if c.reassembled
                    || !c.time_to_repair(now, rtt)
                    || c.rounds >= if c.header.is_idr { 6 } else { 2 }
                    || c.last_repair.is_some_and(|last| now - last < rtt.max(NACK_INTERVAL))
                {
                    return None;
                }
                if feedback.missing_ranges().last().is_some_and(|r| u32::from(r.first) + u32::from(r.count) > u32::from(c.count)) {
                    return None;
                }
                let mut repairs = Vec::new();
                for range in feedback.missing_ranges() {
                    let end = (u32::from(range.first) + u32::from(range.count)).min(u32::from(c.submitted)) as u16;
                    repairs.extend((range.first..end).map(|i| c.fragment(i)));
                }
                if !repairs.is_empty() {
                    c.heard = true;
                    c.last_repair = Some(now);
                    c.rounds += 1;
                    return Some(SendEvent::Repair(repairs));
                }
            }
        }
        None
    }

    pub fn poll(&mut self, now: Instant, rtt: Duration) -> Option<SendEvent> {
        if let Some(h) = self.expired(now) {
            return self.fail(h);
        }
        let c = self.frames.get_mut(&(self.next_frame - 1))?;
        if c.heard || c.reassembled || c.probes >= 2 || !c.time_to_repair(now, rtt) {
            return None;
        }
        let last = c.probe_at.or(c.sent_at)?;
        let quiet = Duration::from_millis(30).max(rtt.saturating_add(rtt / 2).saturating_add(Duration::from_millis(20)));
        if now - last < quiet.saturating_mul(u32::from(c.probes) + 1) {
            return None;
        }
        c.probes += 1;
        c.probe_at = Some(now);
        Some(SendEvent::Repair(vec![c.fragment(c.count - 1)]))
    }
}
