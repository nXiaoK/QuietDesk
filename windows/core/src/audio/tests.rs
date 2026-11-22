use super::*;
use serde_json::{Value, json};

#[test]
fn enabled_status_round_trips_apple_cookie_and_accepts_an_unsolicited_status() {
    let message = Message::json(
        MessageKind::AudioControl,
        &json!({
            "operation":"status","enabled":true,"epoch":9,"sampleRate":48000,"channels":2,"framesPerPacket":960,
            "magicCookie":"T3B1cw==","redundantOpus":true
        }),
    )
    .unwrap();
    let control = AudioControl::read(&message).unwrap();
    assert_eq!(
        control,
        AudioControl::Status {
            request_id: None,
            state: AudioState::Enabled { epoch: NonZeroU32::new(9).unwrap(), magic_cookie: Some(b"Opus".to_vec()), redundant_opus: true }
        }
    );
    assert_eq!(AudioControl::read(&control.message().unwrap()).unwrap(), control);
}

#[test]
fn a_disabled_request_omits_optional_audio_configuration() {
    let id = Uuid::new_v4();
    let request = AudioControl::Request { request_id: id, enabled: false, redundant_opus: false };
    let message = request.message().unwrap();
    assert_eq!(message.read_json::<Value>().unwrap(), json!({"operation":"request","requestID":id,"enabled":false}));
    assert_eq!(AudioControl::read(&message).unwrap(), request);
}

#[test]
fn invalid_status_fields_and_control_payloads_are_rejected_at_the_boundary() {
    let status = json!({"operation":"status","enabled":true,"epoch":1,"sampleRate":48000,"channels":2,"framesPerPacket":960});
    let invalid = |v: &Value| AudioControl::read(&Message::json(MessageKind::AudioControl, v).unwrap()).is_err();
    for (key, bad) in [
        ("epoch", json!(0)),
        ("sampleRate", json!(44100)),
        ("channels", json!(1)),
        ("framesPerPacket", json!(480)),
        ("magicCookie", json!("")),
        ("magicCookie", json!("AA=A")),
        ("magicCookie", json!("AA==\u{2003}")),
        ("magicCookie", json!(encode_block(&[0; 257]))),
        ("error", json!("unexpected")),
    ] {
        let mut message = status.clone();
        message[key] = bad;
        assert!(invalid(&message), "{key}");
    }
    assert!(invalid(&json!({"operation":"request","enabled":true})));
    assert!(invalid(&json!({"operation":"request","requestID":Uuid::new_v4(),"enabled":false,"redundantOpus":false})));
    assert!(invalid(&json!({"operation":"status","enabled":false,"error":"x".repeat(241)})));
    assert!(invalid(&json!({"operation":"status","enabled":false,"magicCookie":"AA=="})));
    assert!(AudioControl::read(&Message::new(MessageKind::AudioControl, vec![b' '; 4097])).is_err());
}

#[test]
fn wire_frame_keeps_previous_packet_before_current_packet() {
    let bytes = [1, 1, 2, 0, 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0, 3, 0, 2, 0xf0, 0x33, 0xa1];
    let frame = AudioPacket::read(&bytes).unwrap();
    assert_eq!((frame.epoch().get(), frame.sequence()), (7, 3));
    assert_eq!(frame.previous_opus_payload(), Some(&[0xf0, 0x33][..]));
    assert_eq!(frame.opus_payload(), &[0xa1]);
    assert_eq!(frame.message().payload, bytes);
    let mut first = bytes;
    first[15] = 1;
    assert!(AudioPacket::read(&first).is_err());
    // The ordinary wire allows sequence zero and a single-channel Opus header.
    let mut plain = bytes[..17].to_vec();
    plain[1] = 0;
    plain[2] = 1;
    plain[15] = 0;
    assert_eq!(AudioPacket::read(&plain).unwrap().sequence(), 0);
}

#[test]
fn audio_frame_boundaries_cannot_consume_an_empty_or_oversize_payload() {
    let valid = [1, 1, 2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 7, 8];
    for (offset, bad) in [(0, 2), (1, 2), (2, 0), (2, 3), (3, 1), (7, 0), (17, 0), (17, 2)] {
        let mut bytes = valid;
        bytes[offset] = bad;
        assert!(AudioPacket::read(&bytes).is_err(), "offset {offset} value {bad}");
    }
    for end in 0..20 {
        assert!(AudioPacket::read(&valid[..end]).is_err());
    }
    let mut max = valid.to_vec();
    max.resize(MAX_PACKET_BYTES, 2);
    assert!(AudioPacket::read(&max).is_ok());
    max.push(3);
    assert!(AudioPacket::read(&max).is_err());
}

fn tone(phase: usize) -> [f32; INTERLEAVED_SAMPLES] {
    std::array::from_fn(|i| {
        let freq = if i % 2 == 0 { 330.0 } else { 660.0 };
        (std::f32::consts::TAU * freq * (phase * FRAMES_PER_PACKET + i / 2) as f32 / SAMPLE_RATE as f32).sin() * 0.25
    })
}

#[test]
fn pause_clears_codec_history_and_redundancy_without_reusing_sequence_numbers() {
    let mut codec = AudioEncoder::new(NonZeroU32::new(3).unwrap(), true).unwrap();
    let first = codec.encode(&tone(0)).unwrap();
    let second = codec.encode(&tone(1)).unwrap();
    assert!(first.previous_opus_payload().is_none());
    assert_eq!(second.previous_opus_payload(), Some(first.opus_payload()));
    codec.reset_after_pause().unwrap();
    let resumed = codec.encode(&tone(2)).unwrap();
    assert_eq!(resumed.sequence(), 3);
    assert_eq!(resumed.epoch(), first.epoch());
    assert!(resumed.previous_opus_payload().is_none());
}

#[test]
fn stereo_decoder_recovers_history_for_loss_concealment_and_resumes_live_packets() {
    let epoch = NonZeroU32::new(9).unwrap();
    let mut encoder = AudioEncoder::new(epoch, false).unwrap();
    let mut packets = (0..5).map(|i| encoder.encode(&tone(i)).unwrap()).collect::<Vec<_>>();
    let mut player = AudioPlayout::new(epoch).unwrap();
    player.push(packets.remove(0), 0);
    player.push(packets.remove(0), 0);
    for i in 0..2 {
        assert!(player.next(i).unwrap().is_some());
    }
    player.push(packets.pop().unwrap(), 0);
    for i in 0..3 {
        let samples = player.next(i).unwrap().unwrap();
        assert!(samples.iter().all(|s| s.is_finite() && s.abs() <= 1.0));
        assert!(samples.iter().any(|s| s.abs() > 0.03), "chunk {i} did not contain synthesized or decoded audio");
    }
    assert!(player.next(0).unwrap().is_none());
}

#[test]
fn invalid_opus_payloads_are_skipped_without_losing_the_next_valid_packet() {
    let epoch = NonZeroU32::MIN;
    let mut encoder = AudioEncoder::new(epoch, false).unwrap();
    let mut player = AudioPlayout::new(epoch).unwrap();
    let mut bad = encoder.encode(&tone(0)).unwrap();
    bad.payload = vec![0xff];
    player.push(bad, 0);
    player.push(encoder.encode(&tone(1)).unwrap(), 0);
    let pcm = player.next(0).unwrap().unwrap();
    assert!(pcm.iter().any(|s| s.abs() > 0.03));
    assert!(player.next(0).unwrap().is_none());
}

#[test]
fn restarting_playout_flushes_pending_packets_and_primes_with_the_new_epoch() {
    let epoch = NonZeroU32::MIN;
    let next_epoch = NonZeroU32::new(2).unwrap();
    let mut old = AudioEncoder::new(epoch, false).unwrap();
    let mut new = AudioEncoder::new(next_epoch, false).unwrap();
    let mut player = AudioPlayout::new(epoch).unwrap();
    player.push(old.encode(&tone(0)).unwrap(), 0);
    player.reset(next_epoch).unwrap();
    player.push(old.encode(&tone(1)).unwrap(), 0);
    player.push(new.encode(&tone(0)).unwrap(), 0);
    assert!(player.next(0).unwrap().is_none());
    player.push(new.encode(&tone(1)).unwrap(), 0);
    assert!(player.next(0).unwrap().is_some());
}
