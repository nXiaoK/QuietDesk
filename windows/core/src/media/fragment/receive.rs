use super::*;
use crate::media::FeedbackKind;
use std::collections::BTreeMap;
use tokio::time::Instant;

#[derive(Debug)]
pub enum ReceiveEvent {
    Feedback(MediaFeedback),
    Frame(MediaFrame),
}

struct Assembly {
    header: MediaFrameHeader,
    data: Vec<u8>,
    received: Vec<bool>,
    exposed_at: Vec<Option<Instant>>,
    exposed: usize,
    count: usize,
    first: Instant,
    progress: Instant,
    last_nack: Option<Instant>,
    complete: Option<Instant>,
    fec: Option<Box<fec::Stored>>,
}

impl Assembly {
    fn new(header: MediaFrameHeader, bytes: usize, count: usize, now: Instant) -> Self {
        Self {
            header,
            data: vec![0; bytes],
            received: vec![false; count],
            exposed_at: vec![None; count],
            exposed: 0,
            count: 0,
            first: now,
            progress: now,
            last_nack: None,
            complete: None,
            fec: None,
        }
    }

    fn expose(&mut self, end: usize, now: Instant) {
        if end > self.exposed {
            self.exposed_at[self.exposed..end].fill(Some(now));
            self.exposed = end;
        }
    }

    fn add(&mut self, index: usize, payload: &[u8], now: Instant) -> Result<bool> {
        let start = index * PAYLOAD;
        let slice = &mut self.data[start..start + payload.len()];
        if self.received[index] {
            if slice != payload {
                return Err(DeskError::invalid("重复媒体分片内容冲突"));
            }
            return Ok(false);
        }
        slice.copy_from_slice(payload);
        self.received[index] = true;
        self.count += 1;
        self.expose(index + 1, now);
        self.progress = now;
        if self.count == self.received.len() {
            self.complete = Some(now);
        }
        Ok(true)
    }

    fn repair(&mut self, touched: usize, now: Instant) -> Result<()> {
        let Some(fec) = self.fec.as_ref().filter(|_| self.complete.is_none()) else { return Ok(()) };
        for (i, shard) in fec.recover(touched, &self.data, &self.received)? {
            let length = PAYLOAD.min(self.data.len() - i * PAYLOAD);
            if shard[length..].iter().any(|&b| b != 0) {
                return Err(DeskError::invalid("媒体纠错恢复尾部非零"));
            }
            self.add(i, &shard[..length], now)?;
        }
        Ok(())
    }

    fn missing(&mut self, now: Instant) -> Option<MediaFeedback> {
        if self.complete.is_some() || self.last_nack.is_some_and(|last| now - last < NACK_INTERVAL) {
            return None;
        }
        let stalled = now - self.progress >= NACK_INTERVAL;
        let end = if stalled { self.received.len() } else { self.exposed };
        let due = |i: usize| !self.received[i] && (stalled || self.exposed_at[i].is_some_and(|since| now - since >= REORDER_DELAY));
        let mut ranges = Vec::new();
        let mut i = 0;
        while i < end && ranges.len() < 64 {
            if !due(i) {
                i += 1;
                continue;
            }
            let first = i;
            while i < end && due(i) {
                i += 1;
            }
            ranges.push(FragmentRange { first: first as u16, count: (i - first) as u16 });
        }
        if ranges.is_empty() {
            return None;
        }
        self.last_nack = Some(now);
        Some(MediaFeedback::nack(self.header, ranges).expect("disjoint ranges inside one bounded frame"))
    }
}

enum Slot {
    Gap { since: Instant, last_nack: Option<Instant> },
    Parts(Assembly),
}

pub struct Receiver {
    capacity: usize,
    stream: MediaStreamId,
    /// Oldest frame still charged to the receive window.
    first_unconfirmed: u64,
    /// First access unit not yet delivered to the decoder in reference order.
    next_delivery: u64,
    committed: bool,
    gap_started: Option<Instant>,
    slots: BTreeMap<u64, Slot>,
    buffered: usize,
    last_decoded: Option<(MediaFrameHeader, Instant)>,
    failed: bool,
    p_ttl: Duration,
}

impl Receiver {
    pub fn new(stream: MediaStreamId) -> Self {
        Self::with_capacity(stream, STATIC_FRAMES)
    }

    pub(crate) fn with_capacity(stream: MediaStreamId, capacity: usize) -> Self {
        Self {
            capacity,
            stream,
            first_unconfirmed: 1,
            next_delivery: 1,
            committed: false,
            gap_started: None,
            slots: BTreeMap::new(),
            buffered: 0,
            last_decoded: None,
            failed: false,
            p_ttl: Duration::from_millis(250),
        }
    }

    pub fn set_round_trip(&mut self, rtt: Duration) {
        self.p_ttl = (rtt.min(DECODE_TIMEOUT) * 3 + Duration::from_millis(80)).clamp(Duration::from_millis(250), DECODE_TIMEOUT);
    }

    fn fail(&mut self, header: MediaFrameHeader) -> Vec<ReceiveEvent> {
        self.failed = true;
        self.slots.clear();
        self.buffered = 0;
        vec![ReceiveEvent::Feedback(MediaFeedback::new(FeedbackKind::Expired, header).expect("no missing ranges"))]
    }

    fn gap_header(&self, id: u64) -> MediaFrameHeader {
        MediaFrameHeader { stream: self.stream, frame_id: id, is_idr: id == 1 }
    }

    fn expired(&self, now: Instant) -> Option<MediaFrameHeader> {
        self.slots.iter().find_map(|(id, slot)| match slot {
            Slot::Gap { .. } if *id == self.next_delivery => {
                let h = self.gap_header(*id);
                self.gap_started.filter(|since| now - *since >= if h.is_idr { DECODE_TIMEOUT } else { self.p_ttl }).map(|_| h)
            }
            Slot::Gap { .. } => None,
            Slot::Parts(a) => {
                let expired = if let Some(complete) = a.complete {
                    now - complete >= DECODE_TIMEOUT
                } else {
                    let ttl = if a.header.is_idr { DECODE_TIMEOUT } else { self.p_ttl };
                    let active = !a.header.is_idr && a.count > 4 && now - a.progress < NACK_INTERVAL * 2;
                    now - a.first >= ttl + if active { ttl.min(a.progress - a.first) } else { Duration::ZERO }
                };
                expired.then_some(a.header)
            }
        })
    }

    fn deliver(&mut self, now: Instant) -> Vec<ReceiveEvent> {
        let mut events = Vec::new();
        while self.next_delivery == 1 || self.committed {
            let Some(Slot::Parts(assembly)) = self.slots.get(&self.next_delivery) else { break };
            if assembly.complete.is_none() {
                break;
            }
            let header = assembly.header;
            if self.next_delivery == 1 && !header.is_idr {
                return self.fail(header);
            }
            let Ok(frame) = MediaFrame::from_packet_bytes(header, &assembly.data) else { return self.fail(header) };
            self.next_delivery += 1;
            events.push(ReceiveEvent::Frame(frame));
        }
        if matches!(self.slots.get(&self.next_delivery), Some(Slot::Gap { .. })) {
            self.gap_started.get_or_insert(now);
        } else {
            self.gap_started = None;
        }
        events
    }

    /// The application published the decoded opening IDR. Dependent inputs may now be submitted.
    pub fn committed(&mut self, stream: MediaStreamId, now: Instant) -> Vec<ReceiveEvent> {
        if stream != self.stream || self.failed || self.committed || self.first_unconfirmed == 1 {
            return Vec::new();
        }
        if let Some(header) = self.expired(now) {
            return self.fail(header);
        }
        self.committed = true;
        self.deliver(now)
    }

    /// Early feedback for old, expired or inconsistent records. A fresh frame reserves
    /// its full advertised size before storing either original data or a parity shard.
    fn prepare(&mut self, header: MediaFrameHeader, bytes: usize, count: usize, now: Instant) -> Option<Vec<ReceiveEvent>> {
        if self.failed || header.stream != self.stream {
            return Some(Vec::new());
        }
        if let Some(h) = self.expired(now) {
            return Some(self.fail(h));
        }
        let id = header.frame_id;
        if id < self.first_unconfirmed {
            return Some(
                self.last_decoded.map(|(h, _)| ReceiveEvent::Feedback(MediaFeedback::new(FeedbackKind::Decoded, h).expect("no ranges"))).into_iter().collect(),
            );
        }
        if id == u64::MAX || id - self.first_unconfirmed >= self.capacity as u64 {
            return Some(self.fail(header));
        }
        if let Some(Slot::Parts(a)) = self.slots.get(&id) {
            if a.header != header || a.data.len() != bytes {
                return Some(self.fail(header));
            }
        } else {
            if bytes > BYTE_BUDGET - self.buffered {
                return Some(self.fail(header));
            }
            for missing in self.first_unconfirmed..id {
                self.slots.entry(missing).or_insert(Slot::Gap { since: now, last_nack: None });
            }
            self.slots.insert(id, Slot::Parts(Assembly::new(header, bytes, count, now)));
            self.buffered += bytes;
            if id == self.next_delivery {
                self.gap_started = None;
            } else if matches!(self.slots.get(&self.next_delivery), Some(Slot::Gap { .. })) {
                self.gap_started.get_or_insert(now);
            }
        }
        None
    }

    fn progress(&mut self, header: MediaFrameHeader, index: usize, now: Instant) -> Result<Vec<ReceiveEvent>> {
        let Some(Slot::Parts(a)) = self.slots.get_mut(&header.frame_id) else { unreachable!() };
        if a.repair(index, now).is_err() {
            return Ok(self.fail(header));
        }
        if a.complete.is_none() {
            return Ok(Vec::new());
        }
        let mut events = self.deliver(now);
        if !self.failed {
            events.insert(0, ReceiveEvent::Feedback(MediaFeedback::new(FeedbackKind::Reassembled, header)?));
        }
        Ok(events)
    }

    pub fn push(&mut self, record: &[u8], now: Instant) -> Result<Vec<ReceiveEvent>> {
        let f = Incoming::read(record)?;
        if let Some(events) = self.prepare(f.header, f.bytes, f.count, now) {
            return Ok(events);
        }
        let Some(Slot::Parts(a)) = self.slots.get_mut(&f.header.frame_id) else { unreachable!() };
        match a.add(f.index, f.payload, now) {
            Err(_) => Ok(self.fail(f.header)),
            Ok(false) => Ok(Vec::new()),
            Ok(true) => self.progress(f.header, f.index, now),
        }
    }

    /// Called only for a negotiated outer kind (8 XOR or 10 block FEC).
    pub fn parity(&mut self, kind: u8, bytes: &[u8], now: Instant) -> Result<Vec<ReceiveEvent>> {
        let record = fec::Record::read(kind, bytes)?;
        let header = record.header;
        if let Some(events) = self.prepare(header, record.bytes, record.count, now) {
            return Ok(events);
        }
        let Some(Slot::Parts(a)) = self.slots.get_mut(&header.frame_id) else { unreachable!() };
        let budget = BYTE_BUDGET - self.buffered;
        match a.fec.get_or_insert_with(Box::default).add(&record, budget) {
            Err(_) => return Ok(self.fail(header)),
            Ok(false) => return Ok(Vec::new()),
            Ok(true) => self.buffered += PAYLOAD,
        }
        if a.complete.is_some() {
            return Ok(Vec::new());
        }
        let end = record.exposed_end();
        a.expose(end, now);
        a.progress = now;
        self.progress(header, end - 1, now)
    }

    /// ViewerMedia confirmed a contiguous prefix from actual decoder callbacks and sent its ACK.
    pub fn decoded(&mut self, header: MediaFrameHeader, now: Instant) -> Vec<ReceiveEvent> {
        if self.failed || header.stream != self.stream || !(self.first_unconfirmed..self.next_delivery).contains(&header.frame_id) {
            return Vec::new();
        }
        if let Some(h) = self.expired(now) {
            return self.fail(h);
        }
        if !matches!(self.slots.get(&header.frame_id), Some(Slot::Parts(a)) if a.header == header) {
            return Vec::new();
        }
        for id in self.first_unconfirmed..=header.frame_id {
            let Some(Slot::Parts(assembly)) = self.slots.remove(&id) else { unreachable!("submitted access units form a contiguous prefix") };
            self.buffered -= assembly.data.len() + assembly.fec.as_deref().map_or(0, |fec| fec.bytes);
        }
        self.first_unconfirmed = header.frame_id + 1;
        self.last_decoded = Some((header, now));
        Vec::new()
    }

    pub fn poll(&mut self, now: Instant) -> Vec<ReceiveEvent> {
        if self.failed {
            return Vec::new();
        }
        if let Some(header) = self.expired(now) {
            return self.fail(header);
        }
        let mut events = Vec::new();
        for (&id, slot) in &mut self.slots {
            let feedback = match slot {
                Slot::Parts(a) => a.missing(now),
                Slot::Gap { since, last_nack } if now - *since >= REORDER_DELAY && last_nack.is_none_or(|last| now - last >= NACK_INTERVAL) => {
                    *last_nack = Some(now);
                    let header = MediaFrameHeader { stream: self.stream, frame_id: id, is_idr: id == 1 };
                    Some(MediaFeedback::nack(header, vec![FragmentRange { first: 0, count: 1 }]).expect("one missing fragment"))
                }
                Slot::Gap { .. } => None,
            };
            if let Some(f) = feedback {
                events.push(ReceiveEvent::Feedback(f));
            }
        }
        if let Some((h, last)) = self.last_decoded.as_mut()
            && now - *last >= Duration::from_millis(20)
        {
            *last = now;
            events.push(ReceiveEvent::Feedback(MediaFeedback::new(FeedbackKind::Decoded, *h).expect("no ranges")));
        }
        events
    }
}
