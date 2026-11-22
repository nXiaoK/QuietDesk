//! Fixed-format Opus sound on the authenticated QuietDesk session.
mod playout;
pub use playout::AudioPlayout;

use crate::error::{DeskError, Result};
use crate::wire::{ByteReader, Message, MessageKind};
use openssl::base64::{decode_block, encode_block};
use serde::{Deserialize, Serialize};
use std::num::NonZeroU32;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const SAMPLE_RATE: u32 = 48_000;
pub const CHANNELS: usize = 2;
pub const FRAMES_PER_PACKET: usize = 960;
pub const INTERLEAVED_SAMPLES: usize = FRAMES_PER_PACKET * CHANNELS;
const BIT_RATE: i32 = 96_000;
const HEADER_BYTES: usize = 16;
pub(crate) const DATAGRAM_KIND: u8 = 9;
const MAX_PACKET_BYTES: usize = crate::media::fragment::MAX_RECORD_BYTES;
const MAX_PAYLOAD_BYTES: usize = MAX_PACKET_BYTES - HEADER_BYTES;

#[derive(Debug, PartialEq, Eq)]
pub enum AudioControl {
    Request { request_id: Uuid, enabled: bool, redundant_opus: bool },
    Status { request_id: Option<Uuid>, state: AudioState },
}

#[derive(Debug, PartialEq, Eq)]
pub enum AudioState {
    Enabled { epoch: NonZeroU32, magic_cookie: Option<Vec<u8>>, redundant_opus: bool },
    Disabled { error: Option<String> },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Operation {
    Request,
    Status,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlFields {
    operation: Operation,
    #[serde(rename = "requestID", default, with = "uuid::serde::hyphenated::option", skip_serializing_if = "Option::is_none")]
    request_id: Option<Uuid>,
    enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    epoch: Option<NonZeroU32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    sample_rate: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    channels: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    frames_per_packet: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    magic_cookie: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    redundant_opus: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn check_error(error: Option<&str>) -> Result<()> {
    if error.is_some_and(|s| s.is_empty() || s.graphemes(true).nth(240).is_some()) {
        return Err(DeskError::invalid("远端音频错误描述无效"));
    }
    Ok(())
}

fn check_cookie(cookie: &[u8]) -> Result<()> {
    if !(1..=256).contains(&cookie.len()) {
        return Err(DeskError::invalid("远端音频编码描述无效"));
    }
    Ok(())
}

impl AudioControl {
    pub fn read(message: &Message) -> Result<Self> {
        let f: ControlFields = message.read_json()?;
        let has_format = f.epoch.is_some() || f.sample_rate.is_some() || f.channels.is_some() || f.frames_per_packet.is_some() || f.magic_cookie.is_some();
        match f.operation {
            Operation::Request => {
                let request_id = f.request_id.ok_or_else(|| DeskError::invalid("远端音频请求缺少 ID"))?;
                if has_format || f.error.is_some() || (!f.enabled && f.redundant_opus.is_some()) {
                    return Err(DeskError::invalid("远端音频请求参数无效"));
                }
                Ok(Self::Request { request_id, enabled: f.enabled, redundant_opus: f.redundant_opus == Some(true) })
            }
            Operation::Status if f.enabled => {
                let epoch = f.epoch.ok_or_else(|| DeskError::invalid("远端音频启用状态缺少代次"))?;
                if f.sample_rate != Some(SAMPLE_RATE) || f.channels != Some(CHANNELS) || f.frames_per_packet != Some(FRAMES_PER_PACKET) || f.error.is_some() {
                    return Err(DeskError::invalid("远端音频启用状态参数无效"));
                }
                let magic_cookie = f
                    .magic_cookie
                    .map(|s| {
                        if !s.is_ascii() || s.bytes().any(|b| b.is_ascii_whitespace()) || s.trim_end_matches('=').contains('=') {
                            return Err(DeskError::invalid("远端音频编码描述无效"));
                        }
                        let bytes = decode_block(&s).map_err(|_| DeskError::invalid("远端音频编码描述无效"))?;
                        check_cookie(&bytes)?;
                        Ok(bytes)
                    })
                    .transpose()?;
                Ok(Self::Status {
                    request_id: f.request_id,
                    state: AudioState::Enabled { epoch, magic_cookie, redundant_opus: f.redundant_opus == Some(true) },
                })
            }
            Operation::Status => {
                if has_format || f.redundant_opus.is_some() {
                    return Err(DeskError::invalid("远端音频关闭状态参数无效"));
                }
                check_error(f.error.as_deref())?;
                Ok(Self::Status { request_id: f.request_id, state: AudioState::Disabled { error: f.error } })
            }
        }
    }

    pub fn message(&self) -> Result<Message> {
        let mut f = ControlFields {
            operation: Operation::Status,
            request_id: None,
            enabled: false,
            epoch: None,
            sample_rate: None,
            channels: None,
            frames_per_packet: None,
            magic_cookie: None,
            redundant_opus: None,
            error: None,
        };
        match self {
            Self::Request { request_id, enabled, redundant_opus } => {
                f.operation = Operation::Request;
                f.request_id = Some(*request_id);
                f.enabled = *enabled;
                f.redundant_opus = (*enabled && *redundant_opus).then_some(true);
            }
            Self::Status { request_id, state } => {
                f.request_id = *request_id;
                match state {
                    AudioState::Enabled { epoch, magic_cookie, redundant_opus } => {
                        f.enabled = true;
                        f.epoch = Some(*epoch);
                        f.sample_rate = Some(SAMPLE_RATE);
                        f.channels = Some(CHANNELS);
                        f.frames_per_packet = Some(FRAMES_PER_PACKET);
                        if let Some(cookie) = magic_cookie {
                            check_cookie(cookie)?;
                            f.magic_cookie = Some(encode_block(cookie));
                        }
                        f.redundant_opus = redundant_opus.then_some(true);
                    }
                    AudioState::Disabled { error } => {
                        check_error(error.as_deref())?;
                        f.error.clone_from(error);
                    }
                }
            }
        }
        Message::json(MessageKind::AudioControl, &f)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioPacket {
    epoch: NonZeroU32,
    sequence: u64,
    channels: u8,
    payload: Vec<u8>,
    previous: Option<Vec<u8>>,
}

impl AudioPacket {
    pub fn epoch(&self) -> NonZeroU32 {
        self.epoch
    }
    pub fn sequence(&self) -> u64 {
        self.sequence
    }
    pub fn opus_payload(&self) -> &[u8] {
        &self.payload
    }
    pub fn previous_opus_payload(&self) -> Option<&[u8]> {
        self.previous.as_deref()
    }

    pub fn read(data: &[u8]) -> Result<Self> {
        if !(HEADER_BYTES + 1..=MAX_PACKET_BYTES).contains(&data.len()) {
            return Err(DeskError::invalid("远端音频数据包长度无效"));
        }
        let mut reader = ByteReader::new(data);
        let (version, flags, channels, reserved) = (reader.u8()?, reader.u8()?, reader.u8()?, reader.u8()?);
        if version != 1 || flags > 1 || reserved != 0 || !(1..=2).contains(&channels) {
            return Err(DeskError::invalid("远端音频数据包头部无效"));
        }
        let epoch = NonZeroU32::new(reader.u32()?).ok_or_else(|| DeskError::invalid("远端音频数据包代次无效"))?;
        let sequence = reader.u64()?;
        let previous = if flags == 1 {
            let length = usize::from(reader.u16()?);
            if sequence <= 1 || length == 0 || length >= reader.remaining() {
                return Err(DeskError::invalid("远端音频冗余负载长度无效"));
            }
            Some(reader.bytes(length)?.to_vec())
        } else {
            None
        };
        let payload = reader.bytes(reader.remaining())?.to_vec();
        Ok(Self { epoch, sequence, channels, payload, previous })
    }

    pub fn message(&self) -> Message {
        Message::new(MessageKind::AudioFrame, self.encode(&[]))
    }

    pub(crate) fn datagram(&self) -> Vec<u8> {
        self.encode(&[DATAGRAM_KIND])
    }

    fn encode(&self, prefix: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(prefix.len() + HEADER_BYTES + self.payload.len() + self.previous.as_ref().map_or(0, |p| p.len() + 2));
        bytes.extend_from_slice(prefix);
        bytes.extend_from_slice(&[1, u8::from(self.previous.is_some()), self.channels, 0]);
        bytes.extend_from_slice(&self.epoch.get().to_be_bytes());
        bytes.extend_from_slice(&self.sequence.to_be_bytes());
        if let Some(previous) = &self.previous {
            bytes.extend_from_slice(&(previous.len() as u16).to_be_bytes());
            bytes.extend_from_slice(previous);
        }
        bytes.extend_from_slice(&self.payload);
        bytes
    }
}

fn codec_error(error: opus::Error) -> DeskError {
    DeskError::platform(format!("Opus 音频处理失败：{error}"))
}

pub struct AudioEncoder {
    codec: opus::Encoder,
    epoch: NonZeroU32,
    sequence: u64,
    redundant: bool,
    last: Option<Vec<u8>>,
}

impl AudioEncoder {
    pub fn new(epoch: NonZeroU32, redundant: bool) -> Result<Self> {
        let mut codec = opus::Encoder::new(SAMPLE_RATE, opus::Channels::Stereo, opus::Application::Audio).map_err(codec_error)?;
        codec.set_bitrate(opus::Bitrate::Bits(BIT_RATE)).map_err(codec_error)?;
        Ok(Self { codec, epoch, sequence: 0, redundant, last: None })
    }

    pub fn encode(&mut self, interleaved: &[f32; INTERLEAVED_SAMPLES]) -> Result<AudioPacket> {
        let sequence = self.sequence.checked_add(1).ok_or_else(|| DeskError::platform("远端音频序号已用尽"))?;
        let mut bytes = [0; MAX_PAYLOAD_BYTES];
        let size = self.codec.encode_float(interleaved, &mut bytes).map_err(codec_error)?;
        let payload = bytes[..size].to_vec();
        let previous = self.last.take().filter(|p| p.len() + size + 2 <= MAX_PAYLOAD_BYTES);
        if self.redundant {
            self.last = Some(payload.clone());
        }
        self.sequence = sequence;
        Ok(AudioPacket { epoch: self.epoch, sequence, channels: CHANNELS as u8, payload, previous })
    }

    pub fn reset_after_pause(&mut self) -> Result<()> {
        self.last = None;
        self.codec.reset_state().map_err(codec_error)
    }
}

#[cfg(test)]
mod tests;
