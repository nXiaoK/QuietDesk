//! Schedules the original fragments and time-bounded repairs of one video epoch.
use crate::datagram_path::DatagramPath;
use crate::error::Result;
use crate::media::fragment::{MAX_RECORD_BYTES, OutgoingFragment, RepairCache, SendEvent};
use crate::media::{FeedbackKind, MediaFeedback, MediaFrame, MediaFrameHeader, MediaStreamId};
use std::collections::VecDeque;
use std::time::Duration;
use tokio::time::Instant;

struct Pending {
    fragment: OutgoingFragment,
    repair: bool,
}

pub(crate) struct DatagramFrames {
    pub stream: MediaStreamId,
    cache: RepairCache,
    pending: VecDeque<Pending>,
    next_send: Instant,
    next_poll: Instant,
    megabits: u32,
    marked_repairs: bool,
}

impl DatagramFrames {
    pub fn new(stream: MediaStreamId, megabits: u32, marked_repairs: bool, now: Instant) -> Self {
        Self { stream, cache: RepairCache::new(stream), pending: VecDeque::new(), next_send: now, next_poll: now, megabits: megabits.max(1), marked_repairs }
    }

    pub fn insert(&mut self, frame: MediaFrame, now: Instant, rtt: Duration) -> Result<()> {
        // A key frame needs time to arrive at the negotiated rate before its decode can commit the epoch.
        let backlog = self.pending.len().saturating_mul(MAX_RECORD_BYTES + 1);
        let bytes = backlog + frame.packet.avcc.len();
        let wire_time = self.duration(bytes);
        let minimum = if frame.header.is_idr { Duration::from_secs(1) } else { Duration::from_millis(250) };
        let ttl = (wire_time + rtt * 3 + Duration::from_millis(80)).clamp(minimum, Duration::from_secs(5));
        let fragments = self.cache.insert(&frame, now, now + ttl)?;
        self.pending.extend(fragments.into_iter().map(|fragment| Pending { fragment, repair: false }));
        Ok(())
    }

    fn duration(&self, bytes: usize) -> Duration {
        Duration::from_secs_f64(bytes as f64 * 8.0 / (f64::from(self.megabits) * 1_000_000.0))
    }

    pub fn deadline(&self) -> Instant {
        if self.pending.is_empty() { self.next_poll } else { self.next_send.min(self.next_poll) }
    }

    fn update(&mut self, event: Option<SendEvent>) -> bool {
        match event {
            Some(SendEvent::Expired(_)) => return false,
            Some(SendEvent::Repair(fragments)) => {
                for fragment in fragments.into_iter().rev() {
                    self.pending.push_front(Pending { fragment, repair: true });
                }
            }
            None => {}
        }
        true
    }

    pub fn fully_submitted(&self, header: MediaFrameHeader) -> bool {
        self.stream == header.stream && self.cache.fully_submitted(header)
    }

    pub fn feedback(&mut self, feedback: &MediaFeedback, now: Instant, rtt: Duration) -> bool {
        if feedback.header.stream != self.stream {
            return true;
        }
        let event = self.cache.feedback(feedback, now, rtt);
        if matches!(feedback.kind, FeedbackKind::Decoded | FeedbackKind::Reassembled) {
            self.pending.retain(|pending| self.cache.needs_fragments(pending.fragment.header()));
        }
        self.update(event)
    }

    pub fn pump(&mut self, path: &DatagramPath, now: Instant) -> bool {
        if now >= self.next_poll {
            self.next_poll = now + Duration::from_millis(20);
            let event = self.cache.poll(now, path.rtt);
            if !self.update(event) {
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
        let mut sent = 0;
        // Bound each turn so sending an IDR cannot starve input and control messages.
        for _ in 0..6 {
            let Some(pending) = self.pending.front() else { break };
            let record = pending.fragment.record();
            let size = record.len() + 1;
            let mut datagram = Vec::with_capacity(size);
            datagram.push(if pending.repair && self.marked_repairs { 5 } else { 3 });
            datagram.extend_from_slice(&record);
            if !send(datagram) {
                break;
            }
            if !pending.repair {
                self.cache.submitted(pending.fragment.header(), pending.fragment.index(), now);
            }
            self.pending.pop_front();
            sent += size;
        }
        self.next_send = now + self.duration(sent).max(Duration::from_millis(1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::FragmentRange;
    use crate::video::{EncodedFrame, VideoPacket};
    use uuid::Uuid;

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
            let mut queue = DatagramFrames::new(stream, 8, marked, now);
            queue.insert(frame.clone(), now, Duration::ZERO).unwrap();
            let total = queue.pending.len();
            queue.send_batch(now, |_| false);
            assert_eq!(queue.pending.len(), total);
            assert_eq!(queue.next_send, now + Duration::from_millis(1));
            queue.send_batch(now, |d| d[0] == 3);
            assert_eq!(queue.pending.len(), total - 6);
            assert!(queue.next_send > now + Duration::from_millis(6));
            let ack = MediaFeedback::new(FeedbackKind::Decoded, header).unwrap();
            assert!(queue.feedback(&ack, now, Duration::ZERO));
            assert_eq!(queue.pending.len(), total - 6);
            assert!(!queue.fully_submitted(header));
            queue.send_batch(queue.next_send, |_| true);
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
}
