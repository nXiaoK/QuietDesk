use super::{AudioPacket, FRAMES_PER_PACKET, INTERLEAVED_SAMPLES, SAMPLE_RATE, codec_error};
use crate::error::Result;
use std::collections::BTreeMap;
use std::num::NonZeroU32;

const PREBUFFER: usize = 2;
const WINDOW: usize = 5;
pub const MAX_IN_FLIGHT: usize = 3;

enum Step {
    Packet(Vec<u8>),
    Conceal,
}

struct JitterBuffer {
    epoch: NonZeroU32,
    packets: BTreeMap<u64, Vec<u8>>,
    last_played: Option<u64>,
    started: bool,
}

impl JitterBuffer {
    fn new(epoch: NonZeroU32) -> Self {
        Self { epoch, packets: BTreeMap::new(), last_played: None, started: false }
    }

    fn push(&mut self, packet: AudioPacket, in_flight: usize) {
        let sequence = packet.sequence;
        if packet.epoch != self.epoch || self.last_played.is_some_and(|last| sequence <= last) || self.packets.contains_key(&sequence) {
            return;
        }
        if let Some(previous) = packet.previous {
            // The wire format carries the immediately preceding packet only when sequence > 1.
            let previous_sequence = sequence - 1;
            if self.last_played.is_none_or(|last| previous_sequence > last) {
                self.packets.entry(previous_sequence).or_insert(previous);
            }
        }
        self.packets.insert(sequence, packet.payload);
        let available = WINDOW.saturating_sub(in_flight).max(1);
        while self.packets.len() > available {
            let (oldest, _) = self.packets.pop_first().expect("the queue exceeds its nonzero limit");
            if self.last_played.is_some() {
                self.last_played = Some(oldest);
            }
        }
    }

    fn next(&mut self, in_flight: usize) -> Option<Step> {
        let Some((&first, _)) = self.packets.first_key_value() else {
            if in_flight == 0 {
                self.started = false;
            }
            return None;
        };
        if in_flight >= MAX_IN_FLIGHT || (!self.started && self.packets.len() < PREBUFFER) {
            return None;
        }
        self.started = true;
        if let Some(last) = self.last_played {
            // All queued sequences are strictly newer than the last packet consumed.
            let missing = first - last - 1;
            if missing != 0 {
                if in_flight >= 2 && self.packets.len() < 2 {
                    return None;
                }
                let room = MAX_IN_FLIGHT - in_flight - 1;
                let conceal = missing.min(2).min(room as u64);
                if conceal > 0 {
                    self.last_played = Some(first - conceal);
                    return Some(Step::Conceal);
                }
            }
        }
        self.last_played = Some(first);
        self.packets.pop_first().map(|(_, bytes)| Step::Packet(bytes))
    }
}

/// The caller reports the number of 20 ms chunks still queued on its output device.
pub struct AudioPlayout {
    codec: opus::Decoder,
    jitter: JitterBuffer,
}

impl AudioPlayout {
    pub fn new(epoch: NonZeroU32) -> Result<Self> {
        let codec = opus::Decoder::new(SAMPLE_RATE, opus::Channels::Stereo).map_err(codec_error)?;
        Ok(Self { codec, jitter: JitterBuffer::new(epoch) })
    }

    /// Drop queued audio and codec history when the active epoch or pause state changes.
    pub fn reset(&mut self, epoch: NonZeroU32) -> Result<()> {
        self.jitter = JitterBuffer::new(epoch);
        self.codec.reset_state().map_err(codec_error)
    }

    pub fn push(&mut self, packet: AudioPacket, in_flight: usize) {
        self.jitter.push(packet, in_flight);
    }

    pub fn next(&mut self, in_flight: usize) -> Result<Option<[f32; INTERLEAVED_SAMPLES]>> {
        while let Some(step) = self.jitter.next(in_flight) {
            let bytes: &[u8] = match &step {
                Step::Packet(bytes) if self.codec.get_nb_samples(bytes).ok() == Some(FRAMES_PER_PACKET) => bytes,
                Step::Packet(_) => continue,
                // An empty input asks libopus to synthesize one missing 20 ms frame from its decoder history.
                Step::Conceal => &[],
            };
            let mut pcm = [0.0; INTERLEAVED_SAMPLES];
            match self.codec.decode_float(bytes, &mut pcm, false) {
                Ok(_) => {
                    for sample in &mut pcm {
                        *sample = if sample.is_finite() { sample.clamp(-1.0, 1.0) } else { 0.0 };
                    }
                    return Ok(Some(pcm));
                }
                Err(error) if error.code() == opus::ErrorCode::InvalidPacket => continue,
                Err(error) => return Err(codec_error(error)),
            }
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(epoch: u32, sequence: u64, previous: bool) -> AudioPacket {
        AudioPacket {
            epoch: NonZeroU32::new(epoch).unwrap(),
            sequence,
            channels: 2,
            payload: sequence.to_be_bytes().to_vec(),
            previous: previous.then(|| (sequence - 1).to_be_bytes().to_vec()),
        }
    }

    fn next_packet(jitter: &mut JitterBuffer, in_flight: usize) -> u64 {
        let Some(Step::Packet(bytes)) = jitter.next(in_flight) else { panic!("expected queued packet") };
        u64::from_be_bytes(bytes.try_into().unwrap())
    }

    #[test]
    fn prebuffer_reorders_and_recovers_the_preceding_packet_before_playing_the_current_one() {
        let mut jitter = JitterBuffer::new(NonZeroU32::MIN);
        jitter.push(packet(1, 4, false), 0);
        assert!(jitter.next(0).is_none());
        jitter.push(packet(1, 3, true), 0);
        jitter.push(packet(1, 3, false), 0);
        assert_eq!([next_packet(&mut jitter, 0), next_packet(&mut jitter, 1), next_packet(&mut jitter, 2)], [2, 3, 4]);
        jitter.push(packet(1, 2, false), 0);
        assert!(jitter.next(0).is_none());
        jitter.push(packet(1, 5, false), 0);
        assert!(jitter.next(0).is_none(), "an underrun rearms the two-packet prebuffer");
    }

    #[test]
    fn playout_ignores_other_epochs_and_drops_the_oldest_audio_when_output_is_busy() {
        let epoch = NonZeroU32::new(2).unwrap();
        let mut jitter = JitterBuffer::new(epoch);
        jitter.push(packet(1, 99, true), 1);
        jitter.push(packet(3, 99, true), 1);
        assert!(jitter.packets.is_empty());
        for seq in 1..=10 {
            jitter.push(packet(2, seq, false), 1);
        }
        assert_eq!(jitter.packets.len(), 4);
        assert_eq!(next_packet(&mut jitter, 1), 7);
        assert!(jitter.next(3).is_none());
    }

    #[test]
    fn reordered_packets_have_a_chance_to_bridge_the_gap_while_output_remains_queued() {
        let mut jitter = JitterBuffer::new(NonZeroU32::MIN);
        jitter.push(packet(1, 1, false), 0);
        jitter.push(packet(1, 2, false), 0);
        assert_eq!((next_packet(&mut jitter, 0), next_packet(&mut jitter, 1)), (1, 2));
        jitter.push(packet(1, 4, false), 2);
        assert!(jitter.next(2).is_none());
        jitter.push(packet(1, 3, false), 2);
        assert_eq!(next_packet(&mut jitter, 2), 3);
        assert_eq!(next_packet(&mut jitter, 1), 4);
    }

    #[test]
    fn even_the_largest_sequence_gap_uses_at_most_two_concealed_frames_and_cannot_wrap() {
        let mut jitter = JitterBuffer::new(NonZeroU32::MIN);
        jitter.push(packet(1, 1, false), 0);
        jitter.push(packet(1, u64::MAX, false), 0);
        assert_eq!(next_packet(&mut jitter, 0), 1);
        assert!(matches!(jitter.next(0), Some(Step::Conceal)));
        assert!(matches!(jitter.next(1), Some(Step::Conceal)));
        assert_eq!(next_packet(&mut jitter, 2), u64::MAX);
        jitter.push(packet(1, 0, false), 0);
        assert!(jitter.next(0).is_none());
    }
}
