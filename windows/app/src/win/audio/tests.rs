use super::*;
use std::f64::consts::TAU;
use std::thread;

fn tone_packet(encoder: &mut AudioEncoder, start: usize, hz: [f64; 2]) -> AudioPacket {
    let mut frame = [0.0; INTERLEAVED_SAMPLES];
    for (i, stereo) in frame.as_chunks_mut::<CHANNELS>().0.iter_mut().enumerate() {
        for (sample, frequency) in stereo.iter_mut().zip(hz) {
            *sample = (0.35 * (TAU * frequency * (start + i) as f64 / SAMPLE_RATE as f64).sin()) as f32;
        }
    }
    encoder.encode(&frame).unwrap()
}

fn strength(pcm: &[f32; INTERLEAVED_SAMPLES], channel: usize, hz: f64) -> f64 {
    let (mut real, mut imag) = (0.0, 0.0);
    for (i, &sample) in pcm.iter().skip(channel).step_by(CHANNELS).enumerate() {
        let (sin, cos) = (TAU * hz * i as f64 / SAMPLE_RATE as f64).sin_cos();
        real += f64::from(sample) * cos;
        imag += f64::from(sample) * sin;
    }
    real.hypot(imag) * 2.0 / FRAMES_PER_PACKET as f64
}

fn verify_tones(
    packets: &mpsc::Sender<AudioPacket>,
    capture: &mut mpsc::Receiver<CaptureEvent>,
    encoder: &mut AudioEncoder,
    epoch: NonZeroU32,
    hz: [f64; 2],
    revision: u64,
) {
    let mut decoder = AudioPlayout::new(epoch).unwrap();
    let mut sent = 0;
    let mut matched = 0;
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline && matched < 6 {
        let packet = tone_packet(encoder, sent * FRAMES_PER_PACKET, hz);
        sent += 1;
        let _ = packets.try_send(packet);
        thread::sleep(Duration::from_millis(20));
        while let Ok(event) = capture.try_recv() {
            let CaptureEvent::Packet(packet, id) = event else { panic!("unexpected capture event") };
            assert_eq!(id, revision);
            decoder.push(packet, 0);
            while let Some(pcm) = decoder.next(0).unwrap() {
                if (0..2).all(|ch| {
                    let signal = strength(&pcm, ch, hz[ch]);
                    signal > 0.04 && signal > 4.0 * strength(&pcm, ch, hz[1 - ch])
                }) {
                    matched += 1;
                }
            }
        }
    }
    assert!(matched >= 6, "stereo tones {hz:?} missing from loopback after {sent} packets");
}

#[test]
#[ignore = "requires an isolated Wine prefix with a virtual render device"]
fn wasapi_virtual_stereo_roundtrip_pause_resume() {
    assert_eq!(std::env::var("QUIETDESK_ISOLATED_AUDIO_CHECK").as_deref(), Ok("1"));
    let epoch = NonZeroU32::MIN;
    let (capture_events, mut captured) = mpsc::channel(16);
    let (capture_pause, paused) = watch::channel(AudioRunState { paused: false, revision: 0 });
    let capture = thread::spawn(move || capture_worker(epoch, true, CaptureWorker { events: capture_events, paused }));
    let (packets, receiver) = mpsc::channel(5);
    let (play_events, mut played) = mpsc::channel(2);
    let (play_pause, paused) = watch::channel(AudioRunState { paused: false, revision: 0 });
    let playback = thread::spawn(move || playback_worker(epoch, PlaybackWorker { events: play_events, packets: receiver, paused }));
    if !matches!(captured.blocking_recv(), Some(CaptureEvent::Ready)) {
        panic!("capture startup: {:?}", capture.join());
    }
    if !matches!(played.blocking_recv(), Some(PlaybackEvent::Ready)) {
        panic!("playback startup: {:?}", playback.join());
    }
    let mut encoder = AudioEncoder::new(epoch, true).unwrap();
    verify_tones(&packets, &mut captured, &mut encoder, epoch, [450.0, 1_000.0], 0);
    capture_pause.send_replace(AudioRunState { paused: true, revision: 1 });
    play_pause.send_replace(AudioRunState { paused: true, revision: 1 });
    thread::sleep(Duration::from_millis(200));
    while captured.try_recv().is_ok() {}
    thread::sleep(Duration::from_millis(120));
    assert!(matches!(captured.try_recv(), Err(mpsc::error::TryRecvError::Empty)));
    play_pause.send_replace(AudioRunState { paused: false, revision: 2 });
    capture_pause.send_replace(AudioRunState { paused: false, revision: 2 });
    encoder.reset_after_pause().unwrap();
    verify_tones(&packets, &mut captured, &mut encoder, epoch, [650.0, 1_350.0], 2);
    drop(capture_pause);
    drop(play_pause);
    capture.join().unwrap().unwrap();
    playback.join().unwrap().unwrap();
}
