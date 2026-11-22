//! The `video` message body and the H.264 byte-stream handling around it.
//!
//! On the wire a frame is `VideoPacket` from `Sources/QuietDeskCore/Protocol.swift`: a sequence number,
//! the parameter sets (on keyframes only) and the access unit as length-prefixed NAL units. Windows codecs
//! produce and consume Annex B byte streams, so this module converts between the two.

use crate::error::{DeskError, Result};
use crate::messages::VideoCodec;
use crate::wire::{ByteReader, MAXIMUM_MESSAGE_BYTES};

const HEVC_FLAG: u16 = 0x8000;
const MAXIMUM_PARAMETER_SET_BYTES: usize = 4096;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VideoPacket {
    pub sequence: u32,
    pub codec: VideoCodec,
    /// HEVC only.
    pub vps: Vec<u8>,
    /// Present on keyframes; an empty SPS marks a frame that depends on earlier ones.
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
    /// NAL units, each behind a four-byte big-endian length.
    pub avcc: Vec<u8>,
}

impl VideoPacket {
    pub fn h264(sequence: u32, frame: EncodedFrame) -> Self {
        Self { sequence, codec: VideoCodec::H264, vps: Vec::new(), sps: frame.sps, pps: frame.pps, avcc: frame.avcc }
    }

    pub fn is_key_frame(&self) -> bool {
        !self.sps.is_empty()
    }

    pub(crate) fn encoded_len(&self) -> usize {
        let header = if self.codec == VideoCodec::Hevc { 10 } else { 8 };
        header + self.vps.len() + self.sps.len() + self.pps.len() + self.avcc.len()
    }

    pub fn encode(&self) -> Result<Vec<u8>> {
        let hevc = self.codec == VideoCodec::Hevc;
        let overhead = if hevc { 12_299 } else { 8201 };
        let sets = [&self.vps, &self.sps, &self.pps];
        if sets.iter().any(|set| set.len() > MAXIMUM_PARAMETER_SET_BYTES)
            || (!hevc && !self.vps.is_empty())
            || self.avcc.is_empty()
            || self.avcc.len() >= MAXIMUM_MESSAGE_BYTES - overhead
        {
            return Err(DeskError::invalid("编码帧大小无效"));
        }
        let mut data = Vec::with_capacity(self.encoded_len());
        data.extend_from_slice(&self.sequence.to_be_bytes());
        data.extend_from_slice(&(self.sps.len() as u16 | if hevc { HEVC_FLAG } else { 0 }).to_be_bytes());
        data.extend_from_slice(&(self.pps.len() as u16).to_be_bytes());
        if hevc {
            data.extend_from_slice(&(self.vps.len() as u16).to_be_bytes());
            data.extend_from_slice(&self.vps);
        }
        data.extend_from_slice(&self.sps);
        data.extend_from_slice(&self.pps);
        data.extend_from_slice(&self.avcc);
        Ok(data)
    }

    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.len() >= MAXIMUM_MESSAGE_BYTES {
            return Err(DeskError::invalid("视频帧过大"));
        }
        let mut reader = ByteReader::new(data);
        let sequence = reader.u32()?;
        let sps_field = reader.u16()?;
        let pps_length = usize::from(reader.u16()?);
        let codec = if sps_field & HEVC_FLAG != 0 { VideoCodec::Hevc } else { VideoCodec::H264 };
        let sps_length = usize::from(sps_field & !HEVC_FLAG);
        let vps_length = if codec == VideoCodec::Hevc { usize::from(reader.u16()?) } else { 0 };
        if sps_length > MAXIMUM_PARAMETER_SET_BYTES
            || pps_length > MAXIMUM_PARAMETER_SET_BYTES
            || vps_length > MAXIMUM_PARAMETER_SET_BYTES
            || (sps_length == 0) != (pps_length == 0)
            || (codec == VideoCodec::Hevc && (vps_length == 0) != (sps_length == 0))
        {
            return Err(DeskError::invalid("视频参数无效"));
        }
        let vps = reader.bytes(vps_length)?.to_vec();
        let sps = reader.bytes(sps_length)?.to_vec();
        let pps = reader.bytes(pps_length)?.to_vec();
        let avcc = reader.bytes(reader.remaining())?.to_vec();
        if avcc.is_empty() {
            return Err(DeskError::invalid("空视频帧"));
        }
        nal_units(&avcc)?;
        Ok(Self { sequence, codec, vps, sps, pps, avcc })
    }

    /// The access unit as an Annex B byte stream, with the parameter sets first on a keyframe.
    pub fn annex_b(&self) -> Result<Vec<u8>> {
        let mut stream = Vec::with_capacity(self.avcc.len() + self.vps.len() + self.sps.len() + self.pps.len() + 16);
        let units = [&self.vps[..], &self.sps[..], &self.pps[..]].into_iter().filter(|set| !set.is_empty()).chain(nal_units(&self.avcc)?);
        for unit in units {
            stream.extend_from_slice(&[0, 0, 0, 1]);
            stream.extend_from_slice(unit);
        }
        Ok(stream)
    }
}

/// The NAL units of a length-prefixed access unit.
pub fn nal_units(avcc: &[u8]) -> Result<Vec<&[u8]>> {
    let mut reader = ByteReader::new(avcc);
    let mut units = Vec::new();
    while reader.remaining() > 0 {
        let length = reader.u32()? as usize;
        if length == 0 || length > reader.remaining() {
            return Err(DeskError::invalid("视频数据损坏"));
        }
        units.push(reader.bytes(length)?);
    }
    Ok(units)
}

/// Splits an Annex B byte stream at its three- or four-byte start codes.
pub fn annex_b_units(stream: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut index = 0;
    while index + 3 <= stream.len() {
        if stream[index] == 0 && stream[index + 1] == 0 && stream[index + 2] == 1 {
            starts.push(index + 3);
            index += 3;
        } else {
            index += 1;
        }
    }
    starts
        .iter()
        .enumerate()
        .filter_map(|(position, start)| {
            let end = starts.get(position + 1).map_or(stream.len(), |next| next - 3);
            // The zero bytes before the next start code belong to that start code, not to this unit.
            let unit = &stream[*start..end];
            let trimmed = unit.len() - unit.iter().rev().take_while(|byte| **byte == 0).count();
            (trimmed > 0).then(|| &unit[..trimmed])
        })
        .collect()
}

/// One encoder output ready for a `VideoPacket`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EncodedFrame {
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
    pub avcc: Vec<u8>,
}

impl EncodedFrame {
    pub fn is_key_frame(&self) -> bool {
        !self.sps.is_empty()
    }
}

/// Turns the Annex B output of an H.264 encoder into frames, remembering the parameter sets so that
/// every IDR frame carries them even when the encoder emitted them only once.
#[derive(Default)]
pub struct H264FrameAssembler {
    sps: Vec<u8>,
    pps: Vec<u8>,
}

impl H264FrameAssembler {
    const SLICE: u8 = 1;
    const IDR_SLICE: u8 = 5;
    const SPS: u8 = 7;
    const PPS: u8 = 8;

    /// Parameter sets announced outside the stream, for example in the encoder's output type.
    pub fn set_parameter_sets(&mut self, annex_b: &[u8]) {
        for unit in annex_b_units(annex_b) {
            self.remember(unit);
        }
    }

    fn remember(&mut self, unit: &[u8]) {
        match unit[0] & 0x1F {
            Self::SPS => self.sps = unit.to_vec(),
            Self::PPS => self.pps = unit.to_vec(),
            _ => {}
        }
    }

    /// `Ok(None)` when the output held no picture, as with a lone parameter set.
    pub fn assemble(&mut self, annex_b: &[u8]) -> Result<Option<EncodedFrame>> {
        let mut avcc = Vec::with_capacity(annex_b.len() + 16);
        let mut key = false;
        for unit in annex_b_units(annex_b) {
            let kind = unit[0] & 0x1F;
            self.remember(unit);
            // Only picture data travels in the access unit; the decoder gets parameter sets separately,
            // and delimiters or filler would only add bytes.
            if (Self::SLICE..=Self::IDR_SLICE).contains(&kind) {
                key |= kind == Self::IDR_SLICE;
                avcc.extend_from_slice(&(unit.len() as u32).to_be_bytes());
                avcc.extend_from_slice(unit);
            }
        }
        if avcc.is_empty() {
            return Ok(None);
        }
        if !key {
            return Ok(Some(EncodedFrame { sps: Vec::new(), pps: Vec::new(), avcc }));
        }
        if self.sps.is_empty() || self.pps.is_empty() {
            return Err(DeskError::platform("编码器输出的关键帧缺少参数集"));
        }
        Ok(Some(EncodedFrame { sps: self.sps.clone(), pps: self.pps.clone(), avcc }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn avcc(units: &[&[u8]]) -> Vec<u8> {
        units.iter().flat_map(|unit| (unit.len() as u32).to_be_bytes().into_iter().chain(unit.iter().copied())).collect()
    }

    #[test]
    fn packet_layout_matches_the_macos_encoding() {
        let packet = VideoPacket {
            sequence: 0x0102_0304,
            codec: VideoCodec::H264,
            vps: Vec::new(),
            sps: vec![0x67, 1, 2],
            pps: vec![0x68, 3],
            avcc: avcc(&[&[0x65, 9, 9]]),
        };
        let encoded = packet.encode().unwrap();
        assert_eq!(packet.encoded_len(), encoded.len());
        assert_eq!(encoded, [1, 2, 3, 4, 0, 3, 0, 2, 0x67, 1, 2, 0x68, 3, 0, 0, 0, 3, 0x65, 9, 9]);
        assert_eq!(VideoPacket::decode(&encoded).unwrap(), packet);
        assert_eq!(packet.annex_b().unwrap(), [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 9, 9]);
    }

    #[test]
    fn hevc_packets_keep_their_flag_and_parameter_set() {
        let packet =
            VideoPacket { sequence: 7, codec: VideoCodec::Hevc, vps: vec![0x40, 1], sps: vec![0x42, 1], pps: vec![0x44, 1], avcc: avcc(&[&[0x26, 1]]) };
        let encoded = packet.encode().unwrap();
        assert_eq!(packet.encoded_len(), encoded.len());
        assert_eq!(&encoded[4..10], &[0x80, 2, 0, 2, 0, 2]);
        assert_eq!(VideoPacket::decode(&encoded).unwrap(), packet);
    }

    #[test]
    fn damaged_packets_are_rejected() {
        let good = VideoPacket { sequence: 1, codec: VideoCodec::H264, vps: vec![], sps: vec![], pps: vec![], avcc: avcc(&[&[0x41, 1]]) };
        let encoded = good.encode().unwrap();
        assert!(VideoPacket::decode(&encoded[..encoded.len() - 1]).is_err());
        assert!(VideoPacket::decode(&encoded[..8]).is_err());
        let mut only_sps = encoded.clone();
        only_sps[5] = 1;
        assert!(VideoPacket::decode(&only_sps).is_err());
        let mut empty_unit = encoded.clone();
        empty_unit.extend_from_slice(&[0, 0, 0, 0]);
        assert!(VideoPacket::decode(&empty_unit).is_err());
    }

    #[test]
    fn annex_b_splits_on_both_start_code_lengths() {
        let stream = [0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 3, 0, 0, 3, 1, 0, 0];
        let units = annex_b_units(&stream);
        assert_eq!(units, [&[0x67, 1][..], &[0x68, 2][..], &[0x65, 3, 0, 0, 3, 1][..]]);
        assert!(annex_b_units(&[1, 2, 3]).is_empty());
    }

    #[test]
    fn assembler_attaches_parameter_sets_to_every_key_frame() {
        let mut assembler = H264FrameAssembler::default();
        let first = [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 1, 0x65, 3, 0, 0, 1, 0x65, 4];
        let frame = assembler.assemble(&first).unwrap().unwrap();
        assert_eq!((frame.sps.clone(), frame.pps.clone()), (vec![0x67, 1], vec![0x68, 2]));
        assert_eq!(frame.avcc, avcc(&[&[0x65, 3], &[0x65, 4]]));

        let delta = assembler.assemble(&[0, 0, 0, 1, 0x41, 5]).unwrap().unwrap();
        assert!(!delta.is_key_frame());
        assert_eq!(delta.avcc, avcc(&[&[0x41, 5]]));

        // A later IDR without in-band parameter sets still carries the remembered ones.
        let later = assembler.assemble(&[0, 0, 0, 1, 0x65, 6]).unwrap().unwrap();
        assert_eq!(later.sps, vec![0x67, 1]);
        assert_eq!(assembler.assemble(&[0, 0, 0, 1, 0x67, 9]).unwrap(), None);
        assert_eq!(assembler.assemble(&[0, 0, 0, 1, 0x65, 7]).unwrap().unwrap().sps, vec![0x67, 9]);
    }

    #[test]
    fn a_key_frame_without_known_parameter_sets_is_an_error() {
        assert!(H264FrameAssembler::default().assemble(&[0, 0, 0, 1, 0x65, 1]).is_err());
        let mut announced = H264FrameAssembler::default();
        announced.set_parameter_sets(&[0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2]);
        assert!(announced.assemble(&[0, 0, 0, 1, 0x65, 1]).unwrap().unwrap().is_key_frame());
    }
}
