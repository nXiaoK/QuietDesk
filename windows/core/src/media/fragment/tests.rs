use super::*;
use crate::media::FeedbackKind;
use crate::video::{EncodedFrame, VideoPacket};
use tokio::time::Instant;
use uuid::Uuid;

fn stream() -> MediaStreamId {
    MediaStreamId { session_id: Uuid::parse_str("12345678-1234-4000-8000-010203040506").unwrap(), transport_epoch: 0x01020304, codec_epoch: 0x05060708 }
}

fn frame(id: u64, bytes: usize) -> MediaFrame {
    let idr = id == 1;
    let mut avcc = (bytes as u32).to_be_bytes().to_vec();
    avcc.push(if idr { 0x65 } else { 0x41 });
    avcc.extend((1..bytes).map(|i| i as u8));
    let packet = VideoPacket::h264(
        0x11223343 + id as u32,
        EncodedFrame { sps: if idr { vec![0x67, 0x64] } else { vec![] }, pps: if idr { vec![0x68] } else { vec![] }, avcc },
    );
    MediaFrame::new(stream(), id, packet).unwrap()
}

fn originals(c: &mut RepairCache, f: &MediaFrame, now: Instant) -> Vec<OutgoingFragment> {
    let parts = c.insert(f, now, now + Duration::from_secs(2)).unwrap();
    for p in &parts {
        c.submitted(p.header(), p.index(), now);
    }
    parts
}

#[test]
fn swift_records_match_both_directions_and_reordered_parts_make_one_frame() {
    // QuietDeskCore MediaFragment.fragment and MediaFeedback.encode produced these records.
    let records = [&include_bytes!("vectors/fragment-0.bin")[..], &include_bytes!("vectors/fragment-1.bin")[..]];
    let nack = include_bytes!("vectors/nack.bin");
    let parsed = MediaFeedback::decode(nack).unwrap();
    assert_eq!(parsed.missing_ranges(), [FragmentRange { first: 0, count: 1 }, FragmentRange { first: 4, count: 2 }]);
    assert_eq!(parsed.message().payload, nack);
    let mut rx = Receiver::new(stream());
    let now = Instant::now();
    let source = frame(1, 2048);
    let parts = originals(&mut RepairCache::new(stream()), &source, now);
    assert_eq!(parts.iter().map(OutgoingFragment::record).collect::<Vec<_>>(), records);
    assert!(rx.push(records[1], now).unwrap().is_empty());
    assert!(rx.push(records[1], now).unwrap().is_empty());
    assert!(
        matches!(&rx.push(records[0],now).unwrap()[..], [ReceiveEvent::Feedback(f),ReceiveEvent::Frame(actual)] if f.kind == FeedbackKind::Reassembled && *actual == source)
    );
    assert!(rx.decoded(source.header, now).is_empty());
    assert!(rx.poll(now + Duration::from_millis(19)).is_empty());
    assert!(matches!(&rx.poll(now+Duration::from_millis(20))[..],[ReceiveEvent::Feedback(f)] if f.kind == FeedbackKind::Decoded && f.header == source.header));
}

#[test]
fn exposed_holes_are_repaired_without_requesting_a_tail_that_is_still_being_sent() {
    let source = frame(1, 5100);
    let now = Instant::now();
    let mut tx = RepairCache::new(stream());
    let parts = originals(&mut tx, &source, now);
    let mut rx = Receiver::new(stream());
    rx.push(&parts[1].record(), now).unwrap();
    assert!(rx.poll(now + Duration::from_millis(2)).is_empty());
    let [ReceiveEvent::Feedback(nack)] = &rx.poll(now + Duration::from_millis(3))[..] else { panic!("missing NACK") };
    assert_eq!(nack.missing_ranges(), [FragmentRange { first: 0, count: 1 }]);
    let Some(SendEvent::Repair(repairs)) = tx.feedback(nack, now + Duration::from_millis(3), Duration::ZERO) else { panic!("missing repair") };
    assert_eq!(repairs[0].record(), parts[0].record());
    rx.push(&repairs[0].record(), now + Duration::from_millis(4)).unwrap();
    assert!(rx.poll(now + Duration::from_millis(13)).is_empty());
    let [ReceiveEvent::Feedback(tail)] = &rx.poll(now + Duration::from_millis(14))[..] else { panic!("missing tail") };
    assert_eq!(tail.missing_ranges(), [FragmentRange { first: 2, count: 3 }]);
}

#[test]
fn wholly_missing_frames_request_one_fragment_and_decode_stays_in_reference_order() {
    let (first, second, third) = (frame(1, 32), frame(2, 32), frame(3, 32));
    let now = Instant::now();
    let mut tx = RepairCache::new(stream());
    let mut rx = Receiver::new(stream());
    let a = originals(&mut tx, &first, now);
    let b = originals(&mut tx, &second, now);
    let c = originals(&mut tx, &third, now);
    assert!(matches!(&rx.push(&c[0].record(), now).unwrap()[..], [ReceiveEvent::Feedback(_)]));
    let missing = rx.poll(now + REORDER_DELAY);
    assert_eq!(missing.len(), 2);
    assert!(
        missing.iter().all(|e| matches!(e,ReceiveEvent::Feedback(f) if f.kind == FeedbackKind::Nack && f.missing_ranges() == [FragmentRange{first:0,count:1}]))
    );
    rx.push(&b[0].record(), now + REORDER_DELAY).unwrap();
    assert!(matches!(&rx.push(&a[0].record(),now+REORDER_DELAY).unwrap()[..],[_,ReceiveEvent::Frame(f)] if f.header == first.header));
    assert!(rx.decoded(second.header, now + REORDER_DELAY).is_empty());
    assert!(rx.committed(stream(), now + REORDER_DELAY).is_empty());
    assert!(rx.decoded(first.header, now + REORDER_DELAY).is_empty());
    let delivered = rx.committed(stream(), now + REORDER_DELAY);
    assert!(matches!(&delivered[..], [ReceiveEvent::Frame(a),ReceiveEvent::Frame(b)] if a.header==second.header && b.header==third.header));
    assert!(rx.decoded(third.header, now + REORDER_DELAY).is_empty());
    let repeat = rx.poll(now + REORDER_DELAY + Duration::from_millis(20));
    assert!(matches!(&repeat[..],[ReceiveEvent::Feedback(ack)] if ack.kind==FeedbackKind::Decoded && ack.header==third.header));
}

#[test]
fn bounds_conflicts_expiry_and_stale_epochs_cannot_populate_a_replacement_receiver() {
    let now = Instant::now();
    let first = frame(1, 3000);
    let p = originals(&mut RepairCache::new(stream()), &first, now)[0].record();
    let mut other = Receiver::new(MediaStreamId { codec_epoch: 0, ..stream() });
    assert!(other.push(&p, now).unwrap().is_empty());
    let mut rx = Receiver::new(stream());
    for (offset, value) in [(0, 0), (3, 3), (36, 7), (45, 0xff), (49, 0xff), (52, 0xff)] {
        let mut bad = p.clone();
        bad[offset] = value;
        if bad != p {
            assert!(rx.push(&bad, now).is_err(), "offset {offset}");
        }
    }
    let mut oversized = p.clone();
    oversized.push(1);
    assert!(rx.push(&oversized, now).is_err());
    let mut far = p.clone();
    far[28..36].copy_from_slice(&u64::MAX.to_be_bytes());
    assert!(matches!(&rx.push(&far,now).unwrap()[..],[ReceiveEvent::Feedback(f)] if f.kind == FeedbackKind::Expired));
    assert!(rx.push(&p, now).unwrap().is_empty());
    let mut rx = Receiver::new(stream());
    rx.push(&p, now).unwrap();
    let mut conflict = p.clone();
    *conflict.last_mut().unwrap() ^= 1;
    assert!(matches!(&rx.push(&conflict,now).unwrap()[..],[ReceiveEvent::Feedback(f)] if f.kind == FeedbackKind::Expired));
    let mut rx = Receiver::new(stream());
    rx.push(&p, now).unwrap();
    assert!(matches!(&rx.poll(now+DECODE_TIMEOUT)[..],[ReceiveEvent::Feedback(f)] if f.kind == FeedbackKind::Expired));
    assert!(rx.poll(now + DECODE_TIMEOUT).is_empty());
}

#[test]
fn only_originals_already_sent_are_repaired_and_feedback_cannot_reopen_the_budget() {
    let now = Instant::now();
    let rtt = Duration::from_millis(15);
    let src = frame(1, 2800);
    let mut tx = RepairCache::new(stream());
    let parts = tx.insert(&src, now, now + Duration::from_secs(1)).unwrap();
    let nack = MediaFeedback::nack(src.header, vec![FragmentRange { first: 0, count: 3 }]).unwrap();
    assert!(tx.feedback(&nack, now, rtt).is_none());
    tx.submitted(src.header, 0, now);
    let beyond_frame = MediaFeedback::nack(src.header, vec![FragmentRange { first: 0, count: 4 }]).unwrap();
    assert!(tx.feedback(&beyond_frame, now, rtt).is_none());
    let Some(SendEvent::Repair(repair)) = tx.feedback(&nack, now, rtt) else { panic!("missing repair") };
    assert_eq!(repair.len(), 1);
    for p in &parts[1..] {
        tx.submitted(p.header(), p.index(), now);
    }
    assert!(tx.feedback(&nack, now + Duration::from_millis(14), rtt).is_none());
    for round in 1..6 {
        assert!(matches!(tx.feedback(&nack, now + rtt * round, rtt), Some(SendEvent::Repair(_))));
    }
    assert!(tx.feedback(&nack, now + rtt * 6, rtt).is_none());
    let received = MediaFeedback::new(FeedbackKind::Reassembled, src.header).unwrap();
    assert!(tx.needs_fragments(src.header));
    tx.feedback(&received, now + rtt * 7, rtt);
    assert!(!tx.needs_fragments(src.header));
    assert!(tx.poll(now + Duration::from_secs(2), rtt).is_none());
    tx.feedback(&received, now + Duration::from_secs(4), rtt);
    assert!(matches!(tx.poll(now + rtt * 7 + DECODE_TIMEOUT, rtt), Some(SendEvent::Expired(_))));
    assert!(tx.poll(now + Duration::from_secs(7), rtt).is_none());
}

#[test]
fn an_unheard_final_frame_probes_only_its_last_original_twice() {
    let mut tx = RepairCache::new(stream());
    let now = Instant::now();
    let f = frame(1, 2600);
    let parts = originals(&mut tx, &f, now);
    let tail = parts.last().unwrap().record();
    let at = |n| now + Duration::from_millis(n);
    assert!(tx.poll(at(29), Duration::ZERO).is_none());
    for ms in [30, 90] {
        let Some(SendEvent::Repair(batch)) = tx.poll(at(ms), Duration::ZERO) else { panic!("missing tail probe") };
        assert_eq!(batch.len(), 1);
        assert_eq!(batch[0].record(), tail);
    }
    assert!(tx.poll(at(999), Duration::ZERO).is_none());
    assert!(matches!(tx.poll(at(2000), Duration::ZERO), Some(SendEvent::Expired(h)) if h == f.header));
}

#[test]
fn frame_windows_release_only_credits_named_by_an_authentic_stream_and_header() {
    let mut tx = RepairCache::new(stream());
    let now = Instant::now();
    for id in 1..=6 {
        originals(&mut tx, &frame(id, 32), now);
    }
    let seventh = frame(7, 32);
    assert!(tx.insert(&seventh, now, now + DECODE_TIMEOUT).is_err());
    let h = frame(4, 32).header;
    let wrong = MediaFrameHeader { is_idr: true, ..h };
    tx.feedback(&MediaFeedback::new(FeedbackKind::Decoded, wrong).unwrap(), now, Duration::ZERO);
    assert!(tx.insert(&seventh, now, now + DECODE_TIMEOUT).is_err());
    tx.feedback(&MediaFeedback::new(FeedbackKind::Decoded, h).unwrap(), now, Duration::ZERO);
    for id in 7..=10 {
        originals(&mut tx, &frame(id, 32), now);
    }
    assert!(tx.insert(&frame(11, 32), now, now + DECODE_TIMEOUT).is_err());
}

#[test]
fn claimed_sizes_are_charged_before_receiving_a_second_fragment() {
    let now = Instant::now();
    let mut rx = Receiver::new(stream());
    let mut record = include_bytes!("vectors/fragment-0.bin").to_vec();
    let length = 12 * 1024 * 1024usize;
    record[45..49].copy_from_slice(&(length as u32).to_be_bytes());
    record[51..53].copy_from_slice(&(length.div_ceil(PAYLOAD) as u16).to_be_bytes());
    for id in 1..=3u64 {
        record[28..36].copy_from_slice(&id.to_be_bytes());
        let events = rx.push(&record, now).unwrap();
        if id < 3 {
            assert!(events.is_empty());
        } else {
            assert!(matches!(&events[..],[ReceiveEvent::Feedback(f)] if f.kind == FeedbackKind::Expired));
        }
    }
}

#[test]
fn a_decode_receipt_cannot_retire_unsent_fragments_and_the_opener_keeps_its_submission_proof() {
    let mut cache = RepairCache::new(stream());
    let now = Instant::now();
    let source = frame(1, 2600);
    let header = source.header;
    let fragments = cache.insert(&source, now, now + DECODE_TIMEOUT).unwrap();
    let (last, others) = fragments.split_last().unwrap();
    for part in others {
        cache.submitted(header, part.index(), now);
    }
    assert!(!cache.fully_submitted(header));
    for kind in [FeedbackKind::Reassembled, FeedbackKind::Decoded] {
        cache.feedback(&MediaFeedback::new(kind, header).unwrap(), now, Duration::ZERO);
        assert!(cache.needs_fragments(header));
    }
    cache.submitted(header, last.index(), now);
    assert!(cache.fully_submitted(header));
    cache.feedback(&MediaFeedback::new(FeedbackKind::Decoded, header).unwrap(), now, Duration::ZERO);
    assert!(!cache.needs_fragments(header));
    assert!(cache.fully_submitted(header));
    assert!(!cache.fully_submitted(MediaFrameHeader { is_idr: false, ..header }));
    assert!(!cache.fully_submitted(MediaFrameHeader { frame_id: 2, ..header }));
    assert!(!cache.fully_submitted(MediaFrameHeader { stream: MediaStreamId { transport_epoch: 0, ..stream() }, ..header }));
}

#[test]
fn a_decoder_needing_the_next_access_unit_can_confirm_a_continuous_stream() {
    let now = Instant::now();
    let mut tx = RepairCache::new(stream());
    let mut rx = Receiver::new(stream());
    let opening = frame(1, 32);
    let first = originals(&mut tx, &opening, now);
    assert!(matches!(&rx.push(&first[0].record(), now).unwrap()[..], [_, ReceiveEvent::Frame(_)]));
    rx.decoded(opening.header, now);
    rx.committed(stream(), now);
    tx.feedback(&MediaFeedback::new(FeedbackKind::Decoded, opening.header).unwrap(), now, Duration::ZERO);

    // This buffering transform produces P[n] only when the next access unit arrives.
    let mut buffered: Option<MediaFrameHeader> = None;
    let mut decoded = Vec::new();
    for id in 2..=12 {
        let source = frame(id, 32);
        let parts = originals(&mut tx, &source, now);
        let events = rx.push(&parts[0].record(), now).unwrap();
        let [ReceiveEvent::Feedback(arrival), ReceiveEvent::Frame(input)] = events.as_slice() else { panic!("frame {id} was not submitted to the decoder") };
        assert_eq!((arrival.kind, input.header), (FeedbackKind::Reassembled, source.header));
        if let Some(output) = buffered.replace(input.header) {
            rx.decoded(output, now);
            tx.feedback(&MediaFeedback::new(FeedbackKind::Decoded, output).unwrap(), now, Duration::ZERO);
            decoded.push(output.frame_id);
        }
    }
    assert_eq!(decoded, (2..12).collect::<Vec<_>>());
    let last = rx.poll(now + Duration::from_millis(20));
    assert!(matches!(&last[..],[ReceiveEvent::Feedback(ack)] if ack.kind==FeedbackKind::Decoded && ack.header.frame_id==11));
}

#[test]
fn submitted_frames_stay_in_the_bounded_window_until_the_matching_epoch_decodes_them() {
    let now = Instant::now();
    let mut tx = RepairCache::new(stream());
    let mut rx = Receiver::new(stream());
    for id in 1..=FRAME_WINDOW as u64 + 2 {
        let source = frame(id, 32);
        let parts = originals(&mut tx, &source, now);
        let events = rx.push(&parts[0].record(), now).unwrap();
        if id == FRAME_WINDOW as u64 + 2 {
            assert!(matches!(&events[..],[ReceiveEvent::Feedback(f)] if f.kind==FeedbackKind::Expired));
            break;
        }
        assert!(matches!(&events[..],[_, ReceiveEvent::Frame(input)] if input.header==source.header));
        if id == 1 {
            rx.decoded(source.header, now);
            rx.committed(stream(), now);
        } else {
            rx.decoded(MediaFrameHeader { stream: MediaStreamId { codec_epoch: 0, ..stream() }, ..source.header }, now);
        }
        tx.feedback(&MediaFeedback::new(FeedbackKind::Decoded, source.header).unwrap(), now, Duration::ZERO);
    }
    assert!(rx.decoded(frame(2, 32).header, now).is_empty());
    assert!(rx.poll(now + DECODE_TIMEOUT).is_empty());
}
