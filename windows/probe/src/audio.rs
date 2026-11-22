use super::emit;
use quietdesk_core::audio::{AudioEncoder, AudioPlayout, CHANNELS, FRAMES_PER_PACKET, INTERLEAVED_SAMPLES, SAMPLE_RATE};
use quietdesk_core::audio_session::{AudioCapture, AudioPlayback, CaptureEvent, PlaybackEvent};
use quietdesk_core::error::{DeskError, Result};
use serde_json::json;
use std::num::NonZeroU32;
use std::time::Duration;

pub fn capture(epoch: NonZeroU32, redundant: bool, paused: bool, fail: bool) -> Result<AudioCapture> {
    let (handle, mut worker) = AudioCapture::channel(paused);
    let mut encoder = AudioEncoder::new(epoch, redundant)?;
    tokio::spawn(async move {
        let result: Result<()> = async {
            if fail {
                return Err(DeskError::platform("Synthetic audio capture is unavailable"));
            }
            let _ = worker.events.send(CaptureEvent::Ready).await;
            let mut state = *worker.paused.borrow_and_update();
            let mut base = 0;
            let mut tick = tokio::time::interval(Duration::from_millis(20));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    biased;
                    change = worker.paused.changed() => {
                        if change.is_err() { break; }
                        state = *worker.paused.borrow_and_update();
                        encoder.reset_after_pause()?;
                    }
                    _ = tick.tick(), if !state.paused => {
                        let pcm = std::array::from_fn(|n| {
                            let frequency = [440.0, 880.0][n % CHANNELS];
                            let frame = base + n / CHANNELS;
                            (0.15 * (std::f64::consts::TAU * frequency * frame as f64 / f64::from(SAMPLE_RATE)).sin()) as f32
                        });
                        let packet = encoder.encode(&pcm)?;
                        base += FRAMES_PER_PACKET;
                        if worker.events.send(CaptureEvent::Packet(packet, state.revision)).await.is_err() { break; }
                    }
                }
            }
            Ok(())
        }
        .await;
        if let Err(error) = result {
            let _ = worker.events.send(CaptureEvent::Failed(error)).await;
        }
    });
    Ok(handle)
}

pub fn playback(epoch: NonZeroU32, paused: bool, fail: bool) -> Result<AudioPlayback> {
    let (handle, mut worker) = AudioPlayback::channel(paused);
    let mut playout = AudioPlayout::new(epoch)?;
    tokio::spawn(async move {
        let result: Result<()> = async {
            if fail {
                return Err(DeskError::platform("Synthetic audio playback is unavailable"));
            }
            let _ = worker.events.send(PlaybackEvent::Ready).await;
            loop {
                tokio::select! {
                    biased;
                    change = worker.paused.changed() => {
                        if change.is_err() { break; }
                        while worker.packets.try_recv().is_ok() {}
                        playout.reset(epoch)?;
                    }
                    packet = worker.packets.recv() => {
                        let Some(packet) = packet else { break };
                        if worker.paused.borrow().paused { continue; }
                        let sequence = packet.sequence();
                        playout.push(packet, 0);
                        while let Some(pcm) = playout.next(0)? {
                            let levels = [0, 1].map(|channel| [330.0, 660.0].map(|hz| level(&pcm, channel, hz)));
                            emit(json!({"event":"audioSamples", "epoch":epoch.get(), "receivedSequence":sequence, "frames":FRAMES_PER_PACKET, "levels":levels}));
                        }
                    }
                }
            }
            Ok(())
        }.await;
        if let Err(error) = result {
            let _ = worker.events.send(PlaybackEvent::Failed(error)).await;
        }
    });
    Ok(handle)
}

fn level(pcm: &[f32; INTERLEAVED_SAMPLES], channel: usize, frequency: f64) -> f64 {
    let mut real = 0.0;
    let mut imaginary = 0.0;
    for (index, &sample) in pcm.iter().skip(channel).step_by(CHANNELS).enumerate() {
        let phase = std::f64::consts::TAU * frequency * index as f64 / f64::from(SAMPLE_RATE);
        let sample = f64::from(sample);
        real += sample * phase.cos();
        imaginary += sample * phase.sin();
    }
    2.0 * real.hypot(imaginary) / FRAMES_PER_PACKET as f64
}
