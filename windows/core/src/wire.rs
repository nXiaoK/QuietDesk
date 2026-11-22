use crate::error::{DeskError, Result};
use serde::{Serialize, de::DeserializeOwned};
use tokio::io::{AsyncRead, AsyncReadExt};

pub const VERSION: i64 = 1;
pub const MAXIMUM_MESSAGE_BYTES: usize = 16 * 1024 * 1024;
pub const MAXIMUM_CLIPBOARD_BYTES: usize = 1024 * 1024;
/// JSON control messages are small; the macOS application rejects larger ones before decoding.
pub const MAXIMUM_CONTROL_BYTES: usize = 4096;

/// Message numbers of `MessageKind` in `Sources/QuietDeskCore/Protocol.swift`. A number outside this
/// list ends the connection on either platform, so a peer sends optional kinds only after negotiation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum MessageKind {
    Hello = 1,
    Video = 2,
    Acknowledgement = 3,
    Input = 4,
    Ping = 5,
    Pong = 6,
    Clipboard = 7,
    RequestClipboard = 8,
    ReleaseInput = 9,
    InputStatus = 10,
    ClipboardSettings = 11,
    ClipboardBegin = 12,
    ClipboardEntry = 13,
    ClipboardChunk = 14,
    ClipboardEnd = 15,
    ClipboardReceipt = 16,
    ClipboardCancel = 17,
    StreamSettingsRequest = 18,
    StreamSettingsResult = 19,
    ControlStatus = 20,
    DeviceIdentity = 21,
    SessionEffectsRequest = 22,
    SessionEffectsResult = 23,
    SessionPauseRequest = 24,
    SessionPauseResult = 25,
    MediaControl = 26,
    MediaFrame = 27,
    MediaFeedback = 28,
    CursorControl = 29,
    CursorShape = 30,
    CursorPosition = 31,
    SessionUnlockRequest = 32,
    SessionUnlockResult = 33,
    SessionTermination = 34,
    DesktopActionRequest = 35,
    DesktopActionResult = 36,
    DisplayControl = 37,
    AudioControl = 38,
    AudioFrame = 39,
    QualityProbeControl = 40,
    ClipboardManifest = 41,
    ClipboardPull = 42,
    MappingControl = 43,
    MappingData = 44,
    MappingEof = 45,
    TypeTextRequest = 46,
    TypeTextResult = 47,
}

impl MessageKind {
    const ALL: [Self; 47] = [
        Self::Hello,
        Self::Video,
        Self::Acknowledgement,
        Self::Input,
        Self::Ping,
        Self::Pong,
        Self::Clipboard,
        Self::RequestClipboard,
        Self::ReleaseInput,
        Self::InputStatus,
        Self::ClipboardSettings,
        Self::ClipboardBegin,
        Self::ClipboardEntry,
        Self::ClipboardChunk,
        Self::ClipboardEnd,
        Self::ClipboardReceipt,
        Self::ClipboardCancel,
        Self::StreamSettingsRequest,
        Self::StreamSettingsResult,
        Self::ControlStatus,
        Self::DeviceIdentity,
        Self::SessionEffectsRequest,
        Self::SessionEffectsResult,
        Self::SessionPauseRequest,
        Self::SessionPauseResult,
        Self::MediaControl,
        Self::MediaFrame,
        Self::MediaFeedback,
        Self::CursorControl,
        Self::CursorShape,
        Self::CursorPosition,
        Self::SessionUnlockRequest,
        Self::SessionUnlockResult,
        Self::SessionTermination,
        Self::DesktopActionRequest,
        Self::DesktopActionResult,
        Self::DisplayControl,
        Self::AudioControl,
        Self::AudioFrame,
        Self::QualityProbeControl,
        Self::ClipboardManifest,
        Self::ClipboardPull,
        Self::MappingControl,
        Self::MappingData,
        Self::MappingEof,
        Self::TypeTextRequest,
        Self::TypeTextResult,
    ];

    pub fn from_number(number: u8) -> Option<Self> {
        Self::ALL.get(usize::from(number).checked_sub(1)?).copied()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub kind: MessageKind,
    pub payload: Vec<u8>,
}

impl Message {
    pub fn new(kind: MessageKind, payload: Vec<u8>) -> Self {
        Self { kind, payload }
    }

    pub fn empty(kind: MessageKind) -> Self {
        Self { kind, payload: Vec::new() }
    }

    pub fn json<T: Serialize>(kind: MessageKind, value: &T) -> Result<Self> {
        let payload = serde_json::to_vec(value).map_err(|error| DeskError::invalid(format!("无法编码控制消息：{error}")))?;
        Ok(Self { kind, payload })
    }

    pub fn read_json<T: DeserializeOwned>(&self) -> Result<T> {
        if self.payload.len() > MAXIMUM_CONTROL_BYTES {
            return Err(DeskError::invalid("控制消息过大"));
        }
        serde_json::from_slice(&self.payload).map_err(|error| DeskError::invalid(format!("控制消息格式无效：{error}")))
    }

    /// The bytes on the wire: a big-endian length covering the kind and payload, the kind, the payload.
    pub fn framed(&self) -> Result<Vec<u8>> {
        let body = self.payload.len() + 1;
        if body > MAXIMUM_MESSAGE_BYTES {
            return Err(DeskError::invalid("消息过大"));
        }
        let mut bytes = Vec::with_capacity(4 + body);
        bytes.extend_from_slice(&(body as u32).to_be_bytes());
        bytes.push(self.kind as u8);
        bytes.extend_from_slice(&self.payload);
        Ok(bytes)
    }
}

/// Reads one message. `Ok(None)` is an orderly end of stream between messages.
pub async fn read_message<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Option<Message>> {
    read_message_limited(reader, MAXIMUM_MESSAGE_BYTES).await
}

pub(crate) async fn read_message_limited<R: AsyncRead + Unpin>(reader: &mut R, maximum: usize) -> Result<Option<Message>> {
    let mut header = [0u8; 4];
    match reader.read_exact(&mut header).await {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    let size = u32::from_be_bytes(header) as usize;
    if !(1..=maximum).contains(&size) {
        return Err(DeskError::invalid("无效的消息长度"));
    }
    let kind = MessageKind::from_number(reader.read_u8().await?).ok_or_else(|| DeskError::invalid("无法识别的消息类型"))?;
    let mut payload = vec![0u8; size - 1];
    reader.read_exact(&mut payload).await?;
    Ok(Some(Message { kind, payload }))
}

/// Big-endian reader over a received payload.
pub struct ByteReader<'a> {
    data: &'a [u8],
}

impl<'a> ByteReader<'a> {
    pub fn new(data: &'a [u8]) -> Self {
        Self { data }
    }

    pub fn remaining(&self) -> usize {
        self.data.len()
    }

    pub fn bytes(&mut self, count: usize) -> Result<&'a [u8]> {
        if self.data.len() < count {
            return Err(DeskError::invalid("消息被截断"));
        }
        let (head, tail) = self.data.split_at(count);
        self.data = tail;
        Ok(head)
    }

    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.bytes(1)?[0])
    }

    pub fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.bytes(2)?.try_into().unwrap()))
    }

    pub fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.bytes(4)?.try_into().unwrap()))
    }

    pub fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.bytes(8)?.try_into().unwrap()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kind_numbers_match_the_macos_protocol() {
        assert_eq!(MessageKind::from_number(1), Some(MessageKind::Hello));
        assert_eq!(MessageKind::from_number(26), Some(MessageKind::MediaControl));
        assert_eq!(MessageKind::from_number(34), Some(MessageKind::SessionTermination));
        assert_eq!(MessageKind::from_number(47), Some(MessageKind::TypeTextResult));
        assert_eq!(MessageKind::from_number(0), None);
        assert_eq!(MessageKind::from_number(48), None);
        for number in 1..=47u8 {
            assert_eq!(MessageKind::from_number(number).unwrap() as u8, number);
        }
    }

    #[tokio::test]
    async fn framed_messages_read_back_and_bad_lengths_fail() {
        let message = Message::new(MessageKind::Acknowledgement, vec![0, 0, 0, 9]);
        let framed = message.framed().unwrap();
        assert_eq!(&framed[..5], &[0, 0, 0, 5, 3]);
        let mut stream = framed.as_slice();
        assert_eq!(read_message(&mut stream).await.unwrap(), Some(message));
        assert_eq!(read_message(&mut stream).await.unwrap(), None);

        let mut empty_body: &[u8] = &[0, 0, 0, 0];
        assert!(read_message(&mut empty_body).await.is_err());
        let mut unknown_kind: &[u8] = &[0, 0, 0, 1, 200];
        assert!(read_message(&mut unknown_kind).await.is_err());
        let mut oversized: &[u8] = &[0x01, 0x00, 0x00, 0x01, 1];
        assert!(read_message(&mut oversized).await.is_err());
    }
}
