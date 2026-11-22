//! Reliable video as the macOS `MediaSession` frames it: stream identities, the
//! transaction that opens every stream with a keyframe the viewer has decoded, whole-frame envelopes,
//! and the feedback that takes the place of legacy acknowledgements.
//!
//! A stream stays on its negotiated connection until a new keyframe transaction commits.

use crate::error::{DeskError, Result};
use crate::video::{EncodedFrame, VideoPacket, nal_units};
use crate::wire::{ByteReader, MAXIMUM_MESSAGE_BYTES, Message, MessageKind};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::time::Duration;
use tokio::time::Instant;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaStreamId {
    #[serde(rename = "sessionID")]
    pub session_id: Uuid,
    pub transport_epoch: u32,
    pub codec_epoch: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MediaFrameHeader {
    pub stream: MediaStreamId,
    pub frame_id: u64,
    pub is_idr: bool,
}

const MAGIC: u16 = 0x514D;
const VERSION: u8 = 1;
const HEADER_BYTES: usize = 37;
const FRAME_RECORD: u8 = 1;
const FEEDBACK_RECORD: u8 = 3;
/// A feedback record fits one datagram of the macOS implementation, whatever carries it.
const MAXIMUM_FEEDBACK_BYTES: usize = 1100;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReliablePath {
    Shared,
    Tcp,
}

impl ReliablePath {
    fn name(self) -> &'static str {
        match self {
            Self::Shared => "shared",
            Self::Tcp => "tcp",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct RoutedStream {
    stream: MediaStreamId,
    path: ReliablePath,
}

impl RoutedStream {
    fn transaction(self, operation: MediaOperation, id: Uuid) -> MediaControl {
        MediaControl::transaction(operation, id, self.stream, self.path.name())
    }
}

const FRAME_TIMEOUT: Duration = Duration::from_secs(5);
const TRANSACTION_TIMEOUT: Duration = Duration::from_secs(8);

fn begin(record: u8, header: &MediaFrameHeader, capacity: usize) -> Vec<u8> {
    let mut data = Vec::with_capacity(HEADER_BYTES + capacity);
    data.extend_from_slice(&MAGIC.to_be_bytes());
    data.extend_from_slice(&[VERSION, record]);
    data.extend_from_slice(header.stream.session_id.as_bytes());
    data.extend_from_slice(&header.stream.transport_epoch.to_be_bytes());
    data.extend_from_slice(&header.stream.codec_epoch.to_be_bytes());
    data.extend_from_slice(&header.frame_id.to_be_bytes());
    data.push(u8::from(header.is_idr));
    data
}

fn read_header(reader: &mut ByteReader, record: u8) -> Result<MediaFrameHeader> {
    if reader.u16()? != MAGIC || reader.u8()? != VERSION || reader.u8()? != record {
        return Err(DeskError::invalid("媒体协议或消息类型无效"));
    }
    let session_id = Uuid::from_bytes(reader.bytes(16)?.try_into().expect("sixteen bytes were read"));
    let stream = MediaStreamId { session_id, transport_epoch: reader.u32()?, codec_epoch: reader.u32()? };
    let frame_id = reader.u64()?;
    match reader.u8()? {
        flags @ 0..=1 => Ok(MediaFrameHeader { stream, frame_id, is_idr: flags == 1 }),
        _ => Err(DeskError::invalid("媒体帧标志无效")),
    }
}

/// Whether an H.264 access unit holds an IDR slice, with the header checks the macOS side applies.
fn contains_idr(avcc: &[u8]) -> Result<bool> {
    let mut idr = false;
    for unit in nal_units(avcc)? {
        let header = unit[0];
        if header & 0x80 != 0 || header & 0x1F == 0 {
            return Err(DeskError::invalid("H.264 NAL 头无效"));
        }
        if header & 0x1F == 5 {
            if header & 0x60 == 0 {
                return Err(DeskError::invalid("IDR 参考标志无效"));
            }
            idr = true;
        }
    }
    Ok(idr)
}

/// One encoded frame of a stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaFrame {
    pub header: MediaFrameHeader,
    pub packet: VideoPacket,
}

impl MediaFrame {
    /// Leaves room for the envelope and the message kind in the message size limit.
    const MAXIMUM_PACKET_BYTES: usize = MAXIMUM_MESSAGE_BYTES - HEADER_BYTES - 5;

    /// A stream changes format only at a keyframe: an IDR carries its parameter sets, other frames none.
    fn check(packet: &VideoPacket) -> Result<bool> {
        if packet.codec != crate::messages::VideoCodec::H264 {
            return Err(DeskError::invalid("媒体帧使用了未协商的编码"));
        }
        let idr = contains_idr(&packet.avcc)?;
        let sets = packet.sps.first().is_some_and(|byte| byte & 0x9F == 7) && packet.pps.first().is_some_and(|byte| byte & 0x9F == 8);
        match idr {
            true if !sets => Err(DeskError::invalid("独立恢复帧缺少有效 SPS/PPS")),
            false if !packet.sps.is_empty() || !packet.pps.is_empty() => Err(DeskError::invalid("媒体格式变化必须以 IDR 开始")),
            _ => Ok(idr),
        }
    }

    pub fn new(stream: MediaStreamId, frame_id: u64, packet: VideoPacket) -> Result<Self> {
        let is_idr = Self::check(&packet)?;
        Ok(Self { header: MediaFrameHeader { stream, frame_id, is_idr }, packet })
    }

    pub fn message(&self) -> Result<Message> {
        let packet = self.packet.encode()?;
        if packet.len() > Self::MAXIMUM_PACKET_BYTES {
            return Err(DeskError::invalid("媒体帧超过协议上限"));
        }
        let mut data = begin(FRAME_RECORD, &self.header, 4 + packet.len());
        data.extend_from_slice(&(packet.len() as u32).to_be_bytes());
        data.extend_from_slice(&packet);
        Ok(Message::new(MessageKind::MediaFrame, data))
    }

    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.len() >= MAXIMUM_MESSAGE_BYTES {
            return Err(DeskError::invalid("媒体帧过大"));
        }
        let mut reader = ByteReader::new(data);
        let header = read_header(&mut reader, FRAME_RECORD)?;
        let length = reader.u32()? as usize;
        if length == 0 || length > Self::MAXIMUM_PACKET_BYTES || length != reader.remaining() {
            return Err(DeskError::invalid("媒体帧长度无效"));
        }
        let packet = VideoPacket::decode(reader.bytes(length)?)?;
        if Self::check(&packet)? != header.is_idr {
            return Err(DeskError::invalid("媒体关键帧标志与视频内容不符"));
        }
        Ok(Self { header, packet })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FeedbackKind {
    /// The frame arrived whole.
    Reassembled = 1,
    /// This frame and every earlier one of the stream were decoded.
    Decoded = 2,
    Expired = 3,
    Nack = 4,
}

/// What a viewer reports about a frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaFeedback {
    pub kind: FeedbackKind,
    pub header: MediaFrameHeader,
}

impl MediaFeedback {
    pub fn message(&self) -> Message {
        let mut data = begin(FEEDBACK_RECORD, &self.header, 2);
        // No missing ranges: those belong to datagram repair.
        data.extend_from_slice(&[self.kind as u8, 0]);
        Message::new(MessageKind::MediaFeedback, data)
    }

    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.len() > MAXIMUM_FEEDBACK_BYTES {
            return Err(DeskError::invalid("媒体反馈过大"));
        }
        let mut reader = ByteReader::new(data);
        let header = read_header(&mut reader, FEEDBACK_RECORD)?;
        let kind = match reader.u8()? {
            1 => FeedbackKind::Reassembled,
            2 => FeedbackKind::Decoded,
            3 => FeedbackKind::Expired,
            4 => FeedbackKind::Nack,
            _ => return Err(DeskError::invalid("媒体反馈类型或长度无效")),
        };
        let ranges = usize::from(reader.u8()?);
        if ranges > 64 || reader.remaining() != ranges * 4 || (kind == FeedbackKind::Nack) != (ranges > 0) {
            return Err(DeskError::invalid("媒体反馈类型或长度无效"));
        }
        let mut previous_end = 0;
        for _ in 0..ranges {
            let first = u32::from(reader.u16()?);
            let count = u32::from(reader.u16()?);
            let end = first + count;
            if count == 0 || first < previous_end || end > u32::from(u16::MAX) + 1 {
                return Err(DeskError::invalid("媒体缺片范围重复或溢出"));
            }
            previous_end = end;
        }
        Ok(Self { kind, header })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MediaOperation {
    Request,
    Offer,
    Bind,
    Bound,
    Prepare,
    Ready,
    DecodedReady,
    Commit,
    Committed,
    Abort,
    Recover,
    Stats,
}

mod base64_key {
    use serde::{Deserialize, Deserializer, Serializer, de::Error};

    pub fn serialize<S: Serializer>(value: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(bytes) => serializer.serialize_str(&openssl::base64::encode_block(bytes)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error> {
        let Some(text) = Option::<String>::deserialize(deserializer)? else { return Ok(None) };
        if text.len() % 4 != 0 || text.is_empty() {
            return Err(D::Error::custom("invalid base64"));
        }
        let bytes = openssl::base64::decode_block(&text).map_err(|_| D::Error::custom("invalid base64"))?;
        if openssl::base64::encode_block(&bytes) != text {
            return Err(D::Error::custom("invalid base64"));
        }
        Ok(Some(bytes))
    }
}

/// The JSON message that negotiates the session and moves it from stream to stream. Fields this
/// implementation never sets are still read, so that their presence where they do not belong is refused
/// as the macOS side refuses it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaControl {
    pub operation: MediaOperation,
    #[serde(rename = "sessionID", default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_key")]
    pub token: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "base64_key")]
    pub datagram_key: Option<Vec<u8>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(rename = "transactionID", default, skip_serializing_if = "Option::is_none")]
    pub transaction_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transport_epoch: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec_epoch: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub media_failure: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encode_milliseconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivery_milliseconds: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encode_idle: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mapped_transfer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub receive_frame_window: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fec_fragment_limit: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub marked_repairs: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay_routing: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub datagram_interactive: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dynamic_frame_window: Option<bool>,
    #[serde(rename = "parityFEC", default, skip_serializing_if = "Option::is_none")]
    pub parity_fec: Option<bool>,
    #[serde(rename = "blockFEC", default, skip_serializing_if = "Option::is_none")]
    pub block_fec: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub datagram_audio: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast_recovery: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fast: Option<bool>,
}

impl MediaControl {
    fn new(operation: MediaOperation) -> Self {
        Self {
            operation,
            session_id: None,
            token: None,
            datagram_key: None,
            role: None,
            transaction_id: None,
            transport_epoch: None,
            codec_epoch: None,
            path: None,
            media_failure: None,
            encode_milliseconds: None,
            delivery_milliseconds: None,
            encode_idle: None,
            mapped_transfer: None,
            receive_frame_window: None,
            fec_fragment_limit: None,
            marked_repairs: None,
            relay_routing: None,
            datagram_interactive: None,
            dynamic_frame_window: None,
            parity_fec: None,
            block_fec: None,
            datagram_audio: None,
            fast_recovery: None,
            fast: None,
        }
    }

    pub(crate) fn binding(operation: MediaOperation, session: Uuid, token: &[u8; 32], role: &str) -> Self {
        Self { session_id: Some(session), token: Some(token.to_vec()), role: Some(role.to_owned()), ..Self::new(operation) }
    }

    /// A step of the exchange that opens `stream`.
    fn transaction(operation: MediaOperation, id: Uuid, stream: MediaStreamId, path: &str) -> Self {
        Self {
            session_id: Some(stream.session_id),
            transaction_id: Some(id),
            transport_epoch: Some(stream.transport_epoch),
            codec_epoch: Some(stream.codec_epoch),
            path: Some(path.to_owned()),
            ..Self::new(operation)
        }
    }

    fn recover(stream: MediaStreamId) -> Self {
        Self {
            session_id: Some(stream.session_id),
            transport_epoch: Some(stream.transport_epoch),
            codec_epoch: Some(stream.codec_epoch),
            ..Self::new(MediaOperation::Recover)
        }
    }

    /// The rules of `MediaControl.validate()` on the macOS side.
    pub fn validate(&self) -> Result<()> {
        use MediaOperation::*;
        let operation = self.operation;
        let negotiating = matches!(operation, Request | Offer);
        let flags = [
            self.relay_routing,
            self.datagram_interactive,
            self.dynamic_frame_window,
            self.parity_fec,
            self.block_fec,
            self.datagram_audio,
            self.fast_recovery,
        ];
        let general = self.token.as_ref().is_none_or(|token| token.len() == 32)
            && self.datagram_key.as_ref().is_none_or(|key| key.len() == 32)
            && self.path.as_deref().is_none_or(|path| matches!(path, "udp" | "tcp" | "shared"))
            && (self.media_failure.is_none() || matches!(operation, Abort | Recover))
            && (negotiating || flags.iter().all(Option::is_none))
            && self.receive_frame_window.is_none_or(|window| operation == Request && window > 0)
            && self.fec_fragment_limit.is_none_or(|limit| operation == Request && limit > 0)
            && (self.marked_repairs.is_none() || operation == Request)
            && (self.fast.is_none() || operation == Prepare)
            && (operation == Stats || (self.encode_milliseconds.is_none() && self.encode_idle.is_none() && self.mapped_transfer.is_none()))
            && self.mapped_transfer.as_deref().is_none_or(|state| matches!(state, "transferring" | "waitingForVideoCredit"))
            && self.role.as_deref().is_none_or(|role| matches!(role, "control" | "video" | "bulk" | "portMapping"))
            && self.delivery_milliseconds.is_none_or(|delay| operation == Stats && (0.0..=60_000.0).contains(&delay));
        let no_identity = self.token.is_none() && self.datagram_key.is_none() && self.role.is_none();
        let no_transaction = self.transaction_id.is_none() && self.transport_epoch.is_none() && self.codec_epoch.is_none() && self.path.is_none();
        let specific = match operation {
            Request => self.session_id.is_none() && no_identity && no_transaction,
            Offer => self.session_id.is_some() && self.token.is_some() && self.datagram_key.is_some(),
            Bind | Bound => self.session_id.is_some() && self.token.is_some() && matches!(self.role.as_deref(), Some("video" | "bulk")),
            Prepare | Ready | DecodedReady | Commit | Committed | Abort => {
                self.session_id.is_some()
                    && self.transaction_id.is_some()
                    && self.transport_epoch.is_some()
                    && self.codec_epoch.is_some()
                    && self.path.is_some()
            }
            Recover => self.session_id.is_some() && self.transport_epoch.is_some() && self.codec_epoch.is_some(),
            Stats => {
                self.session_id.is_some() && self.encode_milliseconds.is_some_and(|time| (0.0..=10_000.0).contains(&time)) && no_identity && no_transaction
            }
        };
        if general && specific { Ok(()) } else { Err(DeskError::invalid("媒体协商参数无效")) }
    }

    pub fn message(&self) -> Result<Message> {
        self.validate()?;
        Message::json(MessageKind::MediaControl, self)
    }

    pub fn read(message: &Message) -> Result<Self> {
        let control: Self = message.read_json()?;
        control.validate()?;
        Ok(control)
    }

    fn step(&self, session: Uuid) -> Result<(Uuid, MediaStreamId, &str)> {
        match (self.transaction_id, self.transport_epoch, self.codec_epoch, self.path.as_deref()) {
            (Some(id), Some(transport_epoch), Some(codec_epoch), Some(path)) => {
                Ok((id, MediaStreamId { session_id: session, transport_epoch, codec_epoch }, path))
            }
            _ => Err(DeskError::invalid("媒体切换身份缺失")),
        }
    }
}

/// Whether the capture pipeline may produce frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gate {
    Open,
    Closed,
    /// Exactly one frame, the keyframe that opens a stream.
    One,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HostStage {
    Preparing,
    Ready,
    Producing,
    Decoded,
}

struct HostTransaction {
    id: Uuid,
    route: RoutedStream,
    stage: HostStage,
    key_frame_sent: bool,
    deadline: Instant,
}

struct OutstandingFrame {
    header: MediaFrameHeader,
    deadline: Instant,
    reassembled: bool,
}

#[derive(Debug, PartialEq)]
pub enum HostMediaEvent {
    Send(Box<MediaControl>),
    /// The viewer asked for a new stream. Frames stop; answer with `prepared` once a keyframe can follow.
    Prepare(MediaStreamId),
    /// Encode one keyframe of the screen as it is now.
    ProduceKeyFrame,
    /// This many frames no longer count against the frame window.
    Settled(usize),
}

/// What becomes of a frame from the encoder.
#[derive(Debug)]
pub enum HostFrame {
    /// No stream has been opened yet: the frame travels as a legacy video message.
    Legacy(VideoPacket),
    Media(Message),
    /// The frame belongs to no stream the viewer is receiving.
    Dropped,
}

/// The host's side of the session.
#[derive(Default)]
pub struct HostMedia {
    session: Option<Uuid>,
    credentials: Option<(Vec<u8>, Vec<u8>)>,
    epochs: (u32, u32),
    transaction: Option<HostTransaction>,
    active: Option<RoutedStream>,
    video_bound: bool,
    /// Frames wait for the viewer to open a new stream.
    hold: bool,
    next_frame: u64,
    /// Frames of the current stream the viewer has not reported as decoded.
    unsettled: VecDeque<OutstandingFrame>,
}

impl HostMedia {
    pub fn frame_path(&self) -> ReliablePath {
        self.transaction.as_ref().map(|t| t.route).or(self.active).map_or(ReliablePath::Shared, |r| r.path)
    }

    pub fn set_video_bound(&mut self, bound: bool) -> (usize, Vec<MediaControl>) {
        let interrupted = self.video_bound && !bound && self.frame_path() == ReliablePath::Tcp;
        self.video_bound = bound;
        if interrupted { self.interrupted() } else { (0, Vec::new()) }
    }

    pub fn gate(&self) -> Gate {
        match &self.transaction {
            Some(transaction) if transaction.stage == HostStage::Producing && !transaction.key_frame_sent => Gate::One,
            Some(_) => Gate::Closed,
            None if self.hold => Gate::Closed,
            None => Gate::Open,
        }
    }

    /// Whether a stream is open or being opened, which is when the viewer may negotiate what depends on one.
    pub fn has_stream(&self) -> bool {
        self.active.is_some() || self.transaction.is_some()
    }

    fn offer(&self) -> Option<MediaControl> {
        let (token, key) = self.credentials.clone()?;
        // "tcp" tells the viewer not to try datagrams. No optional capability is repeated, so none is negotiated.
        Some(MediaControl {
            session_id: self.session,
            token: Some(token),
            datagram_key: Some(key),
            path: Some("tcp".to_string()),
            ..MediaControl::new(MediaOperation::Offer)
        })
    }

    /// `paused` refuses new streams, as a paused macOS host does.
    pub fn control(&mut self, control: &MediaControl, paused: bool) -> Result<Vec<HostMediaEvent>> {
        use MediaOperation::*;
        match control.operation {
            Request => {
                if self.session.is_none() {
                    // Both credentials are required by the offer, including on hosts which serve only reliable video.
                    let (mut token, mut key) = (vec![0u8; 32], vec![0u8; 32]);
                    for secret in [&mut token, &mut key] {
                        openssl::rand::rand_bytes(secret).map_err(|error| DeskError::platform(format!("无法生成媒体会话凭据：{error}")))?;
                    }
                    self.session = Some(Uuid::new_v4());
                    self.credentials = Some((token, key));
                }
                return Ok(self.offer().map(|offer| HostMediaEvent::Send(Box::new(offer))).into_iter().collect());
            }
            Bind | Bound => return Err(DeskError::invalid("控制通道不接受媒体绑定消息")),
            Offer | Stats | Recover | Commit => return Ok(Vec::new()),
            Prepare | Ready | DecodedReady | Committed | Abort => {}
        }
        let Some(session) = self.session.filter(|session| control.session_id == Some(*session)) else { return Ok(Vec::new()) };
        let (id, stream, path) = control.step(session)?;
        let refuse = || vec![HostMediaEvent::Send(Box::new(MediaControl::transaction(Abort, id, stream, path)))];
        let current =
            self.transaction.as_mut().filter(|transaction| transaction.id == id && transaction.route.stream == stream && transaction.route.path.name() == path);
        Ok(match control.operation {
            Prepare => match &self.transaction {
                Some(transaction) if transaction.id != id => refuse(),
                Some(transaction) if transaction.route.stream != stream || transaction.route.path.name() != path => {
                    return Err(DeskError::invalid("媒体事务标识冲突"));
                }
                Some(transaction) if transaction.stage != HostStage::Preparing => {
                    vec![HostMediaEvent::Send(Box::new(MediaControl::transaction(Ready, id, stream, path)))]
                }
                Some(_) => Vec::new(),
                None if paused || stream.transport_epoch <= self.epochs.0 || stream.codec_epoch <= self.epochs.1 => refuse(),
                None => {
                    let path = match path {
                        "shared" => ReliablePath::Shared,
                        "tcp" if self.video_bound => ReliablePath::Tcp,
                        _ => return Ok(refuse()),
                    };
                    self.epochs = (stream.transport_epoch, stream.codec_epoch);
                    self.hold = true;
                    self.transaction = Some(HostTransaction {
                        id,
                        route: RoutedStream { stream, path },
                        stage: HostStage::Preparing,
                        key_frame_sent: false,
                        deadline: Instant::now() + TRANSACTION_TIMEOUT,
                    });
                    self.next_frame = 1;
                    let settled = std::mem::take(&mut self.unsettled).len();
                    vec![HostMediaEvent::Settled(settled), HostMediaEvent::Prepare(stream)]
                }
            },
            Ready => match current {
                Some(transaction) if transaction.stage == HostStage::Ready => {
                    transaction.stage = HostStage::Producing;
                    vec![HostMediaEvent::ProduceKeyFrame]
                }
                _ => Vec::new(),
            },
            DecodedReady => match current {
                Some(transaction) if transaction.key_frame_sent => {
                    transaction.stage = HostStage::Decoded;
                    // This confirmation stands for the keyframe's own feedback, which may still be on its way.
                    let settled = self.unsettled.iter().take_while(|frame| frame.header.frame_id == 1).count();
                    self.unsettled.drain(..settled);
                    vec![HostMediaEvent::Settled(settled), HostMediaEvent::Send(Box::new(MediaControl::transaction(Commit, id, stream, path)))]
                }
                _ => Vec::new(),
            },
            Committed => match current {
                Some(transaction) if transaction.stage == HostStage::Decoded => {
                    self.active = Some(transaction.route);
                    self.transaction = None;
                    self.hold = false;
                    log::info!("host committed {path} media stream (transport epoch {}, codec epoch {})", stream.transport_epoch, stream.codec_epoch);
                    Vec::new()
                }
                _ => Vec::new(),
            },
            // The viewer tries again by itself; frames stay held until it does.
            _ => {
                if current.is_some() {
                    self.transaction = None;
                    return Ok(vec![HostMediaEvent::Settled(std::mem::take(&mut self.unsettled).len())]);
                }
                Vec::new()
            }
        })
    }

    /// The stream asked for can start with a keyframe: tells the viewer so.
    pub fn prepared(&mut self) -> Option<MediaControl> {
        let transaction = self.transaction.as_mut().filter(|transaction| transaction.stage == HostStage::Preparing)?;
        transaction.stage = HostStage::Ready;
        Some(transaction.route.transaction(MediaOperation::Ready, transaction.id))
    }

    /// The stream being prepared, for what has to be said about it before the viewer hears it is ready.
    pub fn preparing(&self) -> Option<MediaStreamId> {
        self.transaction.as_ref().filter(|transaction| transaction.stage == HostStage::Preparing).map(|transaction| transaction.route.stream)
    }

    pub fn frame(&mut self, sequence: u32, frame: EncodedFrame) -> Result<HostFrame> {
        let stream = match &mut self.transaction {
            Some(transaction) if transaction.stage == HostStage::Producing && !transaction.key_frame_sent && frame.is_key_frame() => {
                transaction.key_frame_sent = true;
                transaction.route.stream
            }
            Some(_) => return Ok(HostFrame::Dropped),
            None if self.hold => return Ok(HostFrame::Dropped),
            None => match self.active {
                Some(route) => route.stream,
                None => return Ok(HostFrame::Legacy(VideoPacket::h264(sequence, frame))),
            },
        };
        let frame = MediaFrame::new(stream, self.next_frame, VideoPacket::h264(sequence, frame))?;
        self.next_frame = self.next_frame.checked_add(1).ok_or_else(|| DeskError::Network("媒体帧序号已耗尽，需要重新连接".to_string()))?;
        let message = frame.message()?;
        self.unsettled.push_back(OutstandingFrame { header: frame.header, deadline: Instant::now() + FRAME_TIMEOUT, reassembled: false });
        Ok(HostFrame::Media(message))
    }

    /// How many frames a viewer's report settles, and what to tell the viewer. A frame it gave up on
    /// calls for a new stream.
    pub fn feedback(&mut self, feedback: &MediaFeedback) -> (usize, Vec<MediaControl>) {
        if self.deadline().is_some_and(|deadline| Instant::now() >= deadline) {
            return self.interrupted();
        }
        let Some(index) =
            self.unsettled.iter().position(|frame| frame.header.stream == feedback.header.stream && frame.header.frame_id == feedback.header.frame_id)
        else {
            return (0, Vec::new());
        };
        let frame = &mut self.unsettled[index];
        match feedback.kind {
            FeedbackKind::Decoded if feedback.header == frame.header => {
                self.unsettled.drain(..=index);
                (index + 1, Vec::new())
            }
            FeedbackKind::Expired => self.interrupted(),
            FeedbackKind::Reassembled if feedback.header == frame.header && !frame.reassembled => {
                frame.reassembled = true;
                frame.deadline = Instant::now() + FRAME_TIMEOUT;
                (0, Vec::new())
            }
            _ => (0, Vec::new()),
        }
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.unsettled.iter().map(|frame| frame.deadline).chain(self.transaction.as_ref().map(|transaction| transaction.deadline)).min()
    }

    pub fn expire(&mut self, now: Instant) -> (usize, Vec<MediaControl>) {
        if self.deadline().is_some_and(|deadline| now >= deadline) { self.interrupted() } else { (0, Vec::new()) }
    }

    /// The encoder started over, or frames resume after a pause: what the viewer holds cannot continue.
    /// Returns how many frames stop counting against the frame window and what to tell the viewer;
    /// frames are held until it has opened a new stream.
    pub fn interrupted(&mut self) -> (usize, Vec<MediaControl>) {
        let aborted = self.transaction.take().map(|transaction| transaction.route.transaction(MediaOperation::Abort, transaction.id));
        self.hold = self.hold || self.active.is_some() || aborted.is_some();
        let settled = std::mem::take(&mut self.unsettled).len();
        (settled, aborted.into_iter().chain(self.recovery()).collect())
    }

    /// Stops the exchange in progress; a paused host opens no stream.
    pub fn paused(&mut self) -> Option<MediaControl> {
        let transaction = self.transaction.take()?;
        Some(transaction.route.transaction(MediaOperation::Abort, transaction.id))
    }

    /// The request for a new stream, while frames are held and the viewer has not asked yet.
    pub fn recovery(&self) -> Option<MediaControl> {
        self.active.filter(|_| self.hold && self.transaction.is_none()).map(|route| MediaControl::recover(route.stream))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ViewerStage {
    Preparing,
    Ready,
    Decoded,
}

struct ViewerTransaction {
    id: Uuid,
    route: RoutedStream,
    stage: ViewerStage,
    started: Instant,
}

/// Identifies the decoder submission even when an encoder restarts its packet sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecodeReceipt {
    Legacy(u32),
    Media(MediaStreamId, u32),
}

struct PendingMediaDecode {
    sequence: u32,
    header: MediaFrameHeader,
    deadline: Instant,
    decoded: bool,
    bytes: usize,
}

struct ReceivingStream {
    stream: MediaStreamId,
    next_frame: u64,
    pending: VecDeque<PendingMediaDecode>,
    last_decoded: Option<MediaFrameHeader>,
}

#[derive(Debug)]
pub enum ViewerMediaEvent {
    Send(Message),
    /// A frame to decode and whether the host needs its decoded receipt before sending another.
    Video(VideoPacket, MediaStreamId, bool),
    /// Frames of this stream are now what the viewer shows.
    Committed(MediaStreamId),
}

/// The viewer's side of the session. The viewer decides when a stream is opened.
#[derive(Default)]
pub struct ViewerMedia {
    session: Option<Uuid>,
    epochs: (u32, u32),
    transaction: Option<ViewerTransaction>,
    active: Option<RoutedStream>,
    video_bound: bool,
    receiving: Option<ReceivingStream>,
    auxiliary_enabled: bool,
    legacy_decodes: VecDeque<(u32, usize)>,
    retry_at: Option<Instant>,
    paused: bool,
}

impl ViewerMedia {
    const RETRY_DELAY: Duration = Duration::from_millis(500);
    // Legacy frames may still await acceptance when the first media keyframe arrives.
    const MAXIMUM_PENDING_FRAMES: usize = 6;
    const MAXIMUM_PENDING_BYTES: usize = 32 * 1024 * 1024;

    /// Asks the host for a session. No optional capability is named, so the host uses none.
    pub fn request() -> MediaControl {
        MediaControl::new(MediaOperation::Request)
    }

    pub fn active(&self) -> Option<MediaStreamId> {
        self.active.map(|route| route.stream)
    }

    pub fn enable_auxiliary(&mut self) {
        self.auxiliary_enabled = true;
    }

    pub fn set_video_bound(&mut self, bound: bool, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if !self.auxiliary_enabled || self.video_bound == bound {
            return Ok(Vec::new());
        }
        self.video_bound = bound;
        let route = self.transaction.as_ref().map(|t| t.route).or(self.active);
        match route {
            None if bound => self.begin(now),
            Some(route) if !bound && route.path == ReliablePath::Tcp => {
                let mut events = Vec::new();
                if let Some(abort) = self.abandon() {
                    events.push(ViewerMediaEvent::Send(abort.message()?));
                }
                events.extend(self.begin(now)?);
                Ok(events)
            }
            _ => Ok(Vec::new()),
        }
    }

    fn begin(&mut self, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        let Some(session_id) = self.session.filter(|_| !self.paused && self.transaction.is_none()) else { return Ok(Vec::new()) };
        if self.epochs.0 == u32::MAX || self.epochs.1 == u32::MAX {
            return Err(DeskError::Network("媒体会话代次已耗尽，需要重新连接".to_string()));
        }
        self.epochs = (self.epochs.0 + 1, self.epochs.1 + 1);
        let stream = MediaStreamId { session_id, transport_epoch: self.epochs.0, codec_epoch: self.epochs.1 };
        let path = if self.video_bound { ReliablePath::Tcp } else { ReliablePath::Shared };
        let transaction = ViewerTransaction { id: Uuid::new_v4(), route: RoutedStream { stream, path }, stage: ViewerStage::Preparing, started: now };
        let prepare = MediaControl::transaction(MediaOperation::Prepare, transaction.id, stream, path.name()).message()?;
        self.receiving = None;
        self.transaction = Some(transaction);
        self.retry_at = None;
        Ok(vec![ViewerMediaEvent::Send(prepare)])
    }

    /// Retires every pending decode of the abandoned transaction.
    fn abandon(&mut self) -> Option<MediaControl> {
        self.receiving = None;
        let transaction = self.transaction.take()?;
        Some(transaction.route.transaction(MediaOperation::Abort, transaction.id))
    }

    pub fn control(&mut self, control: &MediaControl, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        use MediaOperation::*;
        match control.operation {
            Request | Prepare => return Err(DeskError::invalid("媒体切换请求方向无效")),
            Bind | Bound => return Err(DeskError::invalid("控制通道不接受媒体绑定消息")),
            Offer => {
                if self.session.is_some() {
                    return Ok(Vec::new());
                }
                self.session = control.session_id;
                if self.auxiliary_enabled && !self.video_bound {
                    if !self.paused {
                        self.retry_at = Some(now + Duration::from_millis(1500));
                    }
                    return Ok(Vec::new());
                }
                return self.begin(now);
            }
            _ => {}
        }
        let Some(session) = self.session.filter(|session| control.session_id == Some(*session)) else { return Ok(Vec::new()) };
        match control.operation {
            Stats | DecodedReady | Committed => return Ok(Vec::new()),
            Recover => {
                let named = (control.transport_epoch, control.codec_epoch);
                let current = self.active().map(|stream| (Some(stream.transport_epoch), Some(stream.codec_epoch)));
                return if current == Some(named) { self.begin(now) } else { Ok(Vec::new()) };
            }
            _ => {}
        }
        let (id, stream, path) = control.step(session)?;
        let Some(transaction) =
            self.transaction.as_mut().filter(|transaction| transaction.id == id && transaction.route.stream == stream && transaction.route.path.name() == path)
        else {
            return Ok(Vec::new());
        };
        Ok(match (control.operation, transaction.stage) {
            (Ready, ViewerStage::Preparing) => {
                transaction.stage = ViewerStage::Ready;
                self.receiving = Some(ReceivingStream { stream, next_frame: 1, pending: VecDeque::new(), last_decoded: None });
                vec![ViewerMediaEvent::Send(MediaControl::transaction(Ready, id, stream, path).message()?)]
            }
            (Commit, ViewerStage::Decoded) => {
                self.active = Some(transaction.route);
                self.transaction = None;
                log::info!("viewer committed {path} media stream (transport epoch {}, codec epoch {})", stream.transport_epoch, stream.codec_epoch);
                vec![ViewerMediaEvent::Committed(stream), ViewerMediaEvent::Send(MediaControl::transaction(Committed, id, stream, path).message()?)]
            }
            (Abort, _) => {
                self.abandon();
                self.retry_at = Some(now + Self::RETRY_DELAY);
                Vec::new()
            }
            _ => Vec::new(),
        })
    }

    pub fn frame(&mut self, payload: &[u8], now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        self.frame_on(ReliablePath::Shared, payload, now)
    }

    pub fn frame_on(&mut self, path: ReliablePath, payload: &[u8], now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if self.session.is_none() {
            return Err(DeskError::invalid("媒体帧会话尚未协商"));
        }
        if self.transaction.as_ref().map(|t| t.route).or(self.active).is_some_and(|route| route.path != path) {
            return Ok(Vec::new());
        }
        let frame = MediaFrame::decode(payload)?;
        let Some(receiver) = self.receiving.as_ref().filter(|receiver| receiver.stream == frame.header.stream) else { return Ok(Vec::new()) };
        let expected = receiver.next_frame;
        if frame.header.frame_id < expected {
            return Ok(receiver
                .last_decoded
                .map(|header| ViewerMediaEvent::Send(MediaFeedback { kind: FeedbackKind::Decoded, header }.message()))
                .into_iter()
                .collect());
        }
        // Frames of a stream arrive in order on this path, and a stream begins with a keyframe.
        if frame.header.frame_id > expected || expected == u64::MAX || (expected == 1 && !frame.header.is_idr) {
            let aborted = self.abandon();
            let mut events: Vec<ViewerMediaEvent> = aborted.map(|abort| abort.message().map(ViewerMediaEvent::Send)).transpose()?.into_iter().collect();
            events.extend(self.begin(now)?);
            return Ok(events);
        }
        if expected > 1 && self.transaction.is_some() {
            return Err(DeskError::invalid("媒体流提交前只接受首个关键帧"));
        }
        if receiver.pending.iter().any(|pending| pending.sequence == frame.packet.sequence) {
            return Err(DeskError::invalid("待解码的媒体帧序号重复"));
        }
        self.check_decode_capacity(payload.len())?;
        let receiver = self.receiving.as_mut().expect("the frame belongs to this receiver");
        receiver.pending.push_back(PendingMediaDecode {
            sequence: frame.packet.sequence,
            header: frame.header,
            deadline: now + FRAME_TIMEOUT,
            decoded: false,
            bytes: payload.len(),
        });
        receiver.next_frame += 1;
        let arrived = MediaFeedback { kind: FeedbackKind::Reassembled, header: frame.header };
        Ok(vec![ViewerMediaEvent::Send(arrived.message()), ViewerMediaEvent::Video(frame.packet, frame.header.stream, frame.header.frame_id == 1)])
    }

    pub fn legacy(&mut self, sequence: u32, bytes: usize) -> Result<()> {
        self.check_decode_capacity(bytes)?;
        self.legacy_decodes.push_back((sequence, bytes));
        Ok(())
    }

    fn check_decode_capacity(&self, bytes: usize) -> Result<()> {
        let sizes = self
            .legacy_decodes
            .iter()
            .map(|(_, size)| *size)
            .chain(self.receiving.iter().flat_map(|receiver| receiver.pending.iter().map(|frame| frame.bytes)));
        let (count, used) = sizes.fold((0, 0), |(count, used), size| (count + 1, used + size));
        if count >= Self::MAXIMUM_PENDING_FRAMES || bytes > Self::MAXIMUM_PENDING_BYTES - used {
            return Err(DeskError::invalid("媒体解码队列超过上限"));
        }
        Ok(())
    }

    pub fn decoded(&mut self, receipt: DecodeReceipt) -> Result<Vec<ViewerMediaEvent>> {
        let (stream, sequence) = match receipt {
            DecodeReceipt::Legacy(sequence) => {
                let Some(index) = self.legacy_decodes.iter().position(|(submitted, _)| *submitted == sequence) else { return Ok(Vec::new()) };
                self.legacy_decodes.remove(index);
                return Ok(vec![ViewerMediaEvent::Send(Message::new(MessageKind::Acknowledgement, sequence.to_be_bytes().to_vec()))]);
            }
            DecodeReceipt::Media(stream, sequence) => (stream, sequence),
        };
        let timed_events = self.tick(Instant::now())?;
        if !timed_events.is_empty() {
            return Ok(timed_events);
        }
        let Some(receiver) = self.receiving.as_mut().filter(|receiver| receiver.stream == stream) else { return Ok(Vec::new()) };
        let Some(frame) = receiver.pending.iter_mut().find(|pending| pending.sequence == sequence) else { return Ok(Vec::new()) };
        frame.decoded = true;
        // Feedback is cumulative. A later output must wait for every preceding picture.
        let complete = receiver.pending.iter().take_while(|pending| pending.decoded).count();
        let Some(last) = receiver.pending.drain(..complete).next_back() else { return Ok(Vec::new()) };
        let header = last.header;
        receiver.last_decoded = Some(header);
        let mut events = vec![ViewerMediaEvent::Send(MediaFeedback { kind: FeedbackKind::Decoded, header }.message())];
        if let Some(transaction) = self.transaction.as_mut().filter(|transaction| transaction.stage == ViewerStage::Ready) {
            transaction.stage = ViewerStage::Decoded;
            events.push(ViewerMediaEvent::Send(transaction.route.transaction(MediaOperation::DecodedReady, transaction.id).message()?));
        }
        Ok(events)
    }

    /// When `tick` has something to do.
    pub fn deadline(&self) -> Option<Instant> {
        self.transaction
            .as_ref()
            .map(|transaction| transaction.started + TRANSACTION_TIMEOUT)
            .or(self.retry_at)
            .into_iter()
            .chain(self.awaiting_decode().map(|(_, deadline)| deadline))
            .min()
    }

    fn awaiting_decode(&self) -> Option<(MediaFrameHeader, Instant)> {
        self.receiving.as_ref()?.pending.front().map(|frame| (frame.header, frame.deadline))
    }

    pub fn tick(&mut self, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        let mut events = Vec::new();
        if let Some((header, _)) = self.awaiting_decode().filter(|(_, deadline)| now >= *deadline) {
            events.push(ViewerMediaEvent::Send(MediaFeedback { kind: FeedbackKind::Expired, header }.message()));
            if self.transaction.as_ref().is_some_and(|pending| pending.route.stream == header.stream) {
                events.extend(self.abandon().map(|abort| abort.message().map(ViewerMediaEvent::Send)).transpose()?);
                self.retry_at = Some(now + Self::RETRY_DELAY);
            } else {
                events.extend(self.begin(now)?);
            }
        } else if self.transaction.as_ref().is_some_and(|transaction| now >= transaction.started + TRANSACTION_TIMEOUT) {
            events.extend(self.abandon().map(|abort| abort.message().map(ViewerMediaEvent::Send)).transpose()?);
            self.retry_at = Some(now + Self::RETRY_DELAY);
        } else if self.retry_at.is_some_and(|at| now >= at) {
            self.retry_at = None;
            events.extend(self.begin(now)?);
        }
        Ok(events)
    }

    /// A paused session opens no stream; a resumed one opens a new one at once.
    pub fn set_paused(&mut self, paused: bool, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if self.paused == paused {
            return Ok(Vec::new());
        }
        self.paused = paused;
        if !paused {
            return self.begin(now);
        }
        self.retry_at = None;
        self.abandon().map(|abort| abort.message().map(ViewerMediaEvent::Send)).transpose().map(|abort| abort.into_iter().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(transport_epoch: u32) -> MediaStreamId {
        MediaStreamId { session_id: Uuid::from_bytes([0x11; 16]), transport_epoch, codec_epoch: transport_epoch + 4 }
    }

    fn key_frame() -> EncodedFrame {
        EncodedFrame { sps: vec![0x67, 0x42], pps: vec![0x68, 0xCE], avcc: vec![0, 0, 0, 2, 0x65, 0x88] }
    }

    fn dependent_frame() -> EncodedFrame {
        EncodedFrame { sps: Vec::new(), pps: Vec::new(), avcc: vec![0, 0, 0, 2, 0x41, 0x9A] }
    }

    #[test]
    fn a_frame_has_the_macos_byte_layout_and_reads_back() {
        let frame = MediaFrame::new(stream(2), 0x0102, VideoPacket::h264(9, key_frame())).unwrap();
        let message = frame.message().unwrap();
        let mut expected = vec![0x51, 0x4D, 1, 1];
        expected.extend_from_slice(&[0x11; 16]);
        expected.extend_from_slice(&[0, 0, 0, 2, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 1, 2, 1]);
        let packet = VideoPacket::h264(9, key_frame()).encode().unwrap();
        expected.extend_from_slice(&(packet.len() as u32).to_be_bytes());
        expected.extend_from_slice(&packet);
        assert_eq!((message.kind, &message.payload), (MessageKind::MediaFrame, &expected));
        assert_eq!(MediaFrame::decode(&message.payload).unwrap(), frame);
    }

    #[test]
    fn frames_whose_marking_or_parameter_sets_do_not_fit_their_content_are_refused() {
        let good = MediaFrame::new(stream(1), 1, VideoPacket::h264(1, key_frame())).unwrap().message().unwrap().payload;
        let mut flipped = good.clone();
        flipped[36] = 0;
        assert!(MediaFrame::decode(&flipped).is_err(), "an IDR marked as dependent");
        flipped[36] = 2;
        assert!(MediaFrame::decode(&flipped).is_err(), "an unknown flag");
        assert!(MediaFrame::decode(&good[..good.len() - 1]).is_err(), "truncated");
        let mut longer = good.clone();
        longer.push(0);
        assert!(MediaFrame::decode(&longer).is_err(), "trailing bytes");
        let mut other_record = good.clone();
        other_record[3] = 3;
        assert!(MediaFrame::decode(&other_record).is_err());

        let without_sets = EncodedFrame { sps: Vec::new(), pps: Vec::new(), ..key_frame() };
        assert!(MediaFrame::new(stream(1), 1, VideoPacket::h264(1, without_sets)).is_err());
        let sets_on_dependent = EncodedFrame { avcc: dependent_frame().avcc, ..key_frame() };
        assert!(MediaFrame::new(stream(1), 2, VideoPacket::h264(2, sets_on_dependent)).is_err());
        let unreferenced_idr = EncodedFrame { avcc: vec![0, 0, 0, 2, 0x05, 0x88], ..key_frame() };
        assert!(MediaFrame::new(stream(1), 1, VideoPacket::h264(1, unreferenced_idr)).is_err());
    }

    #[test]
    fn feedback_has_the_macos_byte_layout_and_refuses_what_does_not_parse() {
        let header = MediaFrameHeader { stream: stream(3), frame_id: 7, is_idr: false };
        let message = MediaFeedback { kind: FeedbackKind::Decoded, header }.message();
        assert_eq!(message.payload.len(), 39);
        assert_eq!(message.payload[..4], [0x51, 0x4D, 1, 3]);
        assert_eq!(message.payload[36..], [0, 2, 0]);
        assert_eq!(MediaFeedback::decode(&message.payload).unwrap(), MediaFeedback { kind: FeedbackKind::Decoded, header });
        // A repair request names ranges; without them, or with them on another kind, it is not one.
        let mut nack = message.payload.clone();
        nack[37] = 4;
        assert!(MediaFeedback::decode(&nack).is_err());
        nack[38] = 1;
        nack.extend_from_slice(&[0, 0, 0, 2]);
        assert_eq!(MediaFeedback::decode(&nack).unwrap().kind, FeedbackKind::Nack);
        let mut overlap = nack.clone();
        overlap[38] = 2;
        overlap.extend_from_slice(&[0, 1, 0, 1]);
        assert!(MediaFeedback::decode(&overlap).is_err());
        for range in [[0, 2, 0, 0], [255, 255, 0, 2]] {
            let mut invalid = nack.clone();
            invalid[39..].copy_from_slice(&range);
            assert!(MediaFeedback::decode(&invalid).is_err());
        }
        nack[37] = 2;
        assert!(MediaFeedback::decode(&nack).is_err());
        let mut unknown = message.payload.clone();
        unknown[37] = 5;
        assert!(MediaFeedback::decode(&unknown).is_err());
    }

    #[test]
    fn controls_use_the_macos_field_names_and_its_validation() {
        let id = Uuid::from_bytes([0x22; 16]);
        let prepare = MediaControl::transaction(MediaOperation::Prepare, id, stream(1), "shared");
        assert_eq!(
            serde_json::to_value(&prepare).unwrap(),
            serde_json::json!({
                "operation": "prepare", "sessionID": "11111111-1111-1111-1111-111111111111",
                "transactionID": "22222222-2222-2222-2222-222222222222", "transportEpoch": 1, "codecEpoch": 5, "path": "shared"
            })
        );
        assert_eq!(serde_json::to_value(ViewerMedia::request()).unwrap(), serde_json::json!({ "operation": "request" }));

        // What a Mac viewer sends first, and a Mac host's answer with its base64 secrets.
        let request: MediaControl = serde_json::from_str(
            r#"{"operation":"request","receiveFrameWindow":6,"markedRepairs":true,"datagramInteractive":true,"dynamicFrameWindow":true,
                "parityFEC":true,"blockFEC":true,"datagramAudio":true,"fecFragmentLimit":1024,"fastRecovery":true,"somethingNewer":1}"#,
        )
        .unwrap();
        request.validate().unwrap();
        assert_eq!((request.parity_fec, request.block_fec, request.fec_fragment_limit), (Some(true), Some(true), Some(1024)));
        let secret = openssl::base64::encode_block(&[7u8; 32]);
        let offer: MediaControl = serde_json::from_str(&format!(
            r#"{{"operation":"offer","sessionID":"11111111-1111-1111-1111-111111111111","token":"{secret}","datagramKey":"{secret}","path":"udp","fastRecovery":true}}"#
        ))
        .unwrap();
        offer.validate().unwrap();
        assert_eq!(offer.token.as_deref(), Some(&[7u8; 32][..]));
        assert_eq!(serde_json::to_value(&offer).unwrap()["datagramKey"], secret);

        let invalid = [
            r#"{"operation":"request","sessionID":"11111111-1111-1111-1111-111111111111"}"#,
            r#"{"operation":"offer","sessionID":"11111111-1111-1111-1111-111111111111"}"#,
            r#"{"operation":"prepare","sessionID":"11111111-1111-1111-1111-111111111111","transportEpoch":1,"codecEpoch":1,"path":"shared"}"#,
            r#"{"operation":"ready","sessionID":"11111111-1111-1111-1111-111111111111","transactionID":"22222222-2222-2222-2222-222222222222","transportEpoch":1,"codecEpoch":1,"path":"direct"}"#,
            r#"{"operation":"commit","sessionID":"11111111-1111-1111-1111-111111111111","transactionID":"22222222-2222-2222-2222-222222222222","transportEpoch":1,"codecEpoch":1,"path":"shared","fast":true}"#,
            r#"{"operation":"recover","sessionID":"11111111-1111-1111-1111-111111111111","transportEpoch":1}"#,
            r#"{"operation":"stats","sessionID":"11111111-1111-1111-1111-111111111111","encodeMilliseconds":20000}"#,
            r#"{"operation":"abort","sessionID":"11111111-1111-1111-1111-111111111111","transactionID":"22222222-2222-2222-2222-222222222222","transportEpoch":1,"codecEpoch":1,"path":"shared","receiveFrameWindow":3}"#,
        ];
        for text in invalid {
            assert!(serde_json::from_str::<MediaControl>(text).unwrap().validate().is_err(), "{text}");
        }
        assert!(
            serde_json::from_str::<MediaControl>(
                r#"{"operation":"offer","sessionID":"11111111-1111-1111-1111-111111111111","token":"AAAA","datagramKey":"AAAA"}"#
            )
            .unwrap()
            .validate()
            .is_err()
        );
        assert!(serde_json::from_str::<MediaControl>(r#"{"operation":"rewind"}"#).is_err());
        assert!(serde_json::from_str::<MediaControl>(r#"{"operation":"offer","token":"===="}"#).is_err());
    }

    /// Runs both sides against each other, delivering every message at once.
    struct Pair {
        host: HostMedia,
        viewer: ViewerMedia,
        now: Instant,
        /// Controls each side sent, in order, for assertions.
        log: Vec<(&'static str, MediaOperation)>,
        prepared: Vec<MediaStreamId>,
        key_frames_wanted: usize,
        settled: usize,
        committed: Vec<MediaStreamId>,
        video: Vec<VideoPacket>,
        stream_openers: Vec<u32>,
    }

    impl Pair {
        fn new() -> Self {
            Self {
                host: HostMedia::default(),
                viewer: ViewerMedia::default(),
                now: Instant::now(),
                log: Vec::new(),
                prepared: Vec::new(),
                key_frames_wanted: 0,
                settled: 0,
                committed: Vec::new(),
                video: Vec::new(),
                stream_openers: Vec::new(),
            }
        }

        fn host_receives(&mut self, control: MediaControl) {
            self.log.push(("viewer", control.operation));
            for event in self.host.control(&control, false).unwrap() {
                match event {
                    HostMediaEvent::Send(reply) => self.viewer_receives(*reply),
                    HostMediaEvent::Prepare(stream) => self.prepared.push(stream),
                    HostMediaEvent::ProduceKeyFrame => self.key_frames_wanted += 1,
                    HostMediaEvent::Settled(count) => self.settled += count,
                }
            }
        }

        fn viewer_receives(&mut self, control: MediaControl) {
            self.log.push(("host", control.operation));
            let events = self.viewer.control(&control, self.now).unwrap();
            self.viewer_events(events);
        }

        fn viewer_events(&mut self, events: Vec<ViewerMediaEvent>) {
            for event in events {
                match event {
                    ViewerMediaEvent::Send(message) if message.kind == MessageKind::MediaControl => self.host_receives(MediaControl::read(&message).unwrap()),
                    ViewerMediaEvent::Send(message) => {
                        let (settled, controls) = self.host.feedback(&MediaFeedback::decode(&message.payload).unwrap());
                        self.settled += settled;
                        assert!(controls.is_empty());
                    }
                    ViewerMediaEvent::Video(packet, _, first_in_stream) => {
                        if first_in_stream {
                            self.stream_openers.push(packet.sequence);
                        }
                        self.video.push(packet);
                    }
                    ViewerMediaEvent::Committed(stream) => self.committed.push(stream),
                }
            }
        }

        /// Sends one encoder frame through the host; returns what became of it.
        fn encode(&mut self, sequence: u32, frame: EncodedFrame) -> &'static str {
            match self.host.frame(sequence, frame).unwrap() {
                HostFrame::Legacy(_) => "legacy",
                HostFrame::Dropped => "dropped",
                HostFrame::Media(message) => {
                    let events = self.viewer.frame_on(self.host.frame_path(), &message.payload, self.now).unwrap();
                    self.viewer_events(events);
                    "media"
                }
            }
        }

        fn decode(&mut self, sequence: u32) {
            let stream = *self.prepared.last().unwrap();
            let events = self.viewer.decoded(DecodeReceipt::Media(stream, sequence)).unwrap();
            self.viewer_events(events);
        }

        fn bind_video(&mut self) {
            let (settled, controls) = self.host.set_video_bound(true);
            assert_eq!(settled, 0);
            assert!(controls.is_empty());
            let events = self.viewer.set_video_bound(true, self.now).unwrap();
            self.viewer_events(events);
        }

        /// The exchange up to the first committed stream.
        fn open(&mut self) {
            self.host_receives(ViewerMedia::request());
            let ready = self.host.prepared().unwrap();
            self.viewer_receives(ready);
            assert_eq!(self.encode(1, key_frame()), "media");
            self.decode(1);
        }
    }

    #[test]
    fn the_offer_waits_for_a_video_bind_and_a_late_bind_keeps_the_shared_transaction() {
        let mut pair = Pair::new();
        pair.viewer.enable_auxiliary();
        pair.host_receives(ViewerMedia::request());
        let initial_deadline = pair.now + Duration::from_millis(1500);
        assert_eq!(pair.viewer.deadline(), Some(initial_deadline));
        pair.host_receives(ViewerMedia::request());
        assert_eq!(pair.viewer.deadline(), Some(initial_deadline));
        assert!(pair.viewer.tick(initial_deadline - Duration::from_millis(1)).unwrap().is_empty());
        let events = pair.viewer.tick(initial_deadline).unwrap();
        pair.viewer_events(events);
        assert_eq!(pair.host.frame_path(), ReliablePath::Shared);
        pair.bind_video();
        let ready = pair.host.prepared().unwrap();
        assert_eq!(ready.path.as_deref(), Some("shared"));
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(1, key_frame()), "media");
        pair.decode(1);
        assert!(pair.viewer.set_video_bound(false, pair.now).unwrap().is_empty());
        assert_eq!(pair.host.set_video_bound(false), (0, Vec::new()));
        assert_eq!(pair.host.gate(), Gate::Open);
    }

    #[test]
    fn a_video_disconnect_reported_after_shared_prepare_keeps_that_cutover_and_its_credit() {
        let mut pair = Pair::new();
        pair.viewer.enable_auxiliary();
        pair.host_receives(ViewerMedia::request());
        pair.bind_video();
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        pair.encode(1, key_frame());
        pair.decode(1);
        let fallback = pair.viewer.set_video_bound(false, pair.now).unwrap();
        pair.viewer_events(fallback);
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        pair.encode(2, key_frame());
        assert_eq!(pair.host.set_video_bound(false), (0, Vec::new()));
        assert_eq!(pair.host.gate(), Gate::Closed);
        pair.decode(2);
        assert_eq!(pair.host.gate(), Gate::Open);
        assert_eq!(pair.host.frame_path(), ReliablePath::Shared);
    }

    #[test]
    fn a_bound_video_path_uses_its_own_frames_and_exact_transaction_messages() {
        let mut pair = Pair::new();
        pair.viewer.enable_auxiliary();
        pair.host_receives(ViewerMedia::request());
        pair.bind_video();
        let ready = pair.host.prepared().unwrap();
        assert_eq!(ready.path.as_deref(), Some("tcp"));
        let mut wrong = ready.clone();
        wrong.path = Some("shared".into());
        assert!(pair.viewer.control(&wrong, pair.now).unwrap().is_empty());
        assert!(pair.host.control(&wrong, false).unwrap().is_empty());
        assert_eq!(pair.host.gate(), Gate::Closed);
        pair.viewer_receives(ready);
        assert_eq!(pair.host.frame_path(), ReliablePath::Tcp);
        let HostFrame::Media(frame) = pair.host.frame(1, key_frame()).unwrap() else { panic!("expected TCP keyframe") };
        assert!(pair.viewer.frame(&frame.payload, pair.now).unwrap().is_empty());
        let accepted = pair.viewer.frame_on(ReliablePath::Tcp, &frame.payload, pair.now).unwrap();
        pair.viewer_events(accepted);
        assert_eq!(pair.host.gate(), Gate::Closed);
        pair.decode(1);
        assert_eq!(pair.host.gate(), Gate::Open);
        assert_eq!(pair.host.frame_path(), ReliablePath::Tcp);
    }

    #[test]
    fn losing_the_video_socket_before_during_or_after_commit_opens_a_new_shared_stream() {
        for stage in 0..3 {
            let mut pair = Pair::new();
            pair.viewer.enable_auxiliary();
            pair.host_receives(ViewerMedia::request());
            pair.bind_video();
            let retired = *pair.prepared.last().unwrap();
            if stage > 0 {
                let ready = pair.host.prepared().unwrap();
                pair.viewer_receives(ready);
                assert_eq!(pair.encode(1, key_frame()), "media");
                if stage == 2 {
                    pair.decode(1);
                    assert_eq!(pair.encode(2, dependent_frame()), "media");
                }
            }
            let (settled, replies) = pair.host.set_video_bound(false);
            assert_eq!(settled, usize::from(stage > 0));
            assert_eq!(replies.len(), 1);
            assert_eq!(replies[0].operation, if stage == 2 { MediaOperation::Recover } else { MediaOperation::Abort });
            assert_eq!(pair.host.gate(), Gate::Closed);
            let fallback = pair.viewer.set_video_bound(false, pair.now).unwrap();
            pair.viewer_events(fallback);
            for reply in replies {
                pair.viewer_receives(reply);
            }
            assert!(pair.viewer.decoded(DecodeReceipt::Media(retired, if stage == 2 { 2 } else { 1 })).unwrap().is_empty());
            let ready = pair.host.prepared().unwrap();
            assert_eq!(ready.path.as_deref(), Some("shared"));
            assert_ne!(ready.transport_epoch, Some(retired.transport_epoch));
            pair.viewer_receives(ready);
            assert_eq!(pair.encode(1, key_frame()), "media");
            pair.decode(1);
            assert_eq!(pair.host.gate(), Gate::Open);
            assert_eq!(pair.host.frame_path(), ReliablePath::Shared);
        }
    }

    #[test]
    fn a_stream_opens_with_one_keyframe_the_viewer_decoded_before_frames_flow() {
        use MediaOperation::*;
        let mut pair = Pair::new();
        assert_eq!((pair.host.gate(), pair.encode(1, key_frame())), (Gate::Open, "legacy"), "no session yet");
        pair.host_receives(ViewerMedia::request());
        assert_eq!(pair.log, [("viewer", Request), ("host", Offer), ("viewer", Prepare)]);
        let first = pair.prepared[0];
        assert_eq!((first.transport_epoch, first.codec_epoch, pair.host.gate()), (1, 1, Gate::Closed));
        assert_eq!(pair.encode(2, dependent_frame()), "dropped", "a frame that was on its way");

        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.log[3..], [("host", Ready), ("viewer", Ready)]);
        assert_eq!((pair.key_frames_wanted, pair.host.gate()), (1, Gate::One));
        assert_eq!(pair.encode(3, dependent_frame()), "dropped", "only a keyframe opens a stream");
        assert_eq!((pair.encode(4, key_frame()), pair.host.gate()), ("media", Gate::Closed));
        assert_eq!(pair.video.len(), 1);
        assert!(pair.committed.is_empty());

        pair.decode(4);
        assert_eq!(pair.log[5..], [("viewer", DecodedReady), ("host", Commit), ("viewer", Committed)]);
        assert_eq!((pair.committed.as_slice(), pair.viewer.active(), pair.host.gate()), (&[first][..], Some(first), Gate::Open));
        assert_eq!(pair.settled, 1, "the keyframe is settled once, by its feedback or the confirmation");

        assert_eq!(pair.encode(5, dependent_frame()), "media");
        assert_eq!(pair.encode(6, dependent_frame()), "media");
        pair.decode(6);
        assert_eq!(pair.settled, 1, "a later picture cannot confirm a missing output");
        pair.decode(5);
        assert_eq!(pair.settled, 3, "both contiguous pictures settle at once");
        assert_eq!(pair.encode(7, key_frame()), "media");
        assert_eq!(pair.stream_openers, [4], "a periodic IDR does not require isolated decoding");
    }

    #[test]
    fn an_interrupted_host_asks_for_a_new_stream_and_holds_frames_until_it_is_open() {
        let mut pair = Pair::new();
        pair.open();
        let first = pair.viewer.active().unwrap();
        assert_eq!(pair.encode(2, dependent_frame()), "media");

        let (unsettled, controls) = pair.host.interrupted();
        assert_eq!(unsettled, 1, "the frame the viewer has not reported no longer counts");
        assert_eq!(controls.iter().map(|control| control.operation).collect::<Vec<_>>(), [MediaOperation::Recover]);
        assert_eq!((pair.host.gate(), pair.host.recovery().is_some()), (Gate::Closed, true));
        assert_eq!(pair.encode(3, key_frame()), "dropped");
        pair.viewer_receives(controls[0].clone());
        let second = pair.prepared[1];
        assert_eq!((second.transport_epoch, second.codec_epoch, pair.host.recovery()), (2, 2, None));
        // As soon as the viewer starts a switch, only the pending transaction can supply frames.
        let late = MediaFrame::new(first, 3, VideoPacket::h264(4, dependent_frame())).unwrap().message().unwrap();
        assert!(pair.viewer.frame(&late.payload, pair.now).unwrap().is_empty());

        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert!(pair.viewer.frame(&late.payload, pair.now).unwrap().is_empty(), "the old stream is over once the new one is ready");
        assert_eq!(pair.encode(5, key_frame()), "media");
        pair.decode(5);
        assert_eq!((pair.viewer.active(), pair.host.gate()), (Some(second), Gate::Open));
        // A repeated request for the stream that was replaced starts nothing.
        pair.viewer_receives(controls[0].clone());
        assert_eq!(pair.prepared.len(), 2);

        // A frame the viewer gave up on, in the middle of an exchange: the exchange is called off and,
        // with a stream in use, a new one asked for.
        pair.viewer_receives(MediaControl::recover(second));
        let third = pair.prepared[2];
        let expired = MediaFeedback { kind: FeedbackKind::Expired, header: MediaFrameHeader { stream: third, frame_id: 1, is_idr: true } };
        assert_eq!(pair.host.feedback(&expired), (0, Vec::new()), "this keyframe has not been sent");
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(6, key_frame()), "media");
        let (_, controls) = pair.host.feedback(&expired);
        assert_eq!(controls.iter().map(|control| control.operation).collect::<Vec<_>>(), [MediaOperation::Abort, MediaOperation::Recover]);
        let stale = MediaFeedback { header: MediaFrameHeader { stream: first, ..expired.header }, ..expired };
        assert_eq!(pair.host.feedback(&stale), (0, Vec::new()), "a report about a stream that is over changes nothing");
    }

    #[test]
    fn shared_frame_feedback_and_deadlines_only_settle_outstanding_frames() {
        let mut pair = Pair::new();
        pair.open();
        let stream = pair.viewer.active().unwrap();
        assert!(pair.host.deadline().is_none());
        assert_eq!(pair.encode(2, dependent_frame()), "media");
        let deadline = pair.host.deadline().unwrap();
        let header = MediaFrameHeader { stream, frame_id: 2, is_idr: false };
        for wrong in [MediaFrameHeader { is_idr: true, ..header }, MediaFrameHeader { frame_id: 3, ..header }] {
            assert_eq!(pair.host.feedback(&MediaFeedback { kind: FeedbackKind::Decoded, header: wrong }), (0, Vec::new()));
        }
        assert_eq!(pair.host.deadline(), Some(deadline));
        // Repeated receipt of an already reassembled frame cannot postpone recovery indefinitely.
        pair.host.feedback(&MediaFeedback { kind: FeedbackKind::Reassembled, header });
        assert_eq!(pair.host.deadline(), Some(deadline));
        assert_eq!(pair.host.expire(deadline - Duration::from_millis(1)), (0, Vec::new()));
        assert_eq!(pair.host.expire(deadline), (1, vec![MediaControl::recover(stream)]));
        assert!(pair.host.deadline().is_none());
        assert_eq!(pair.host.gate(), Gate::Closed);

        let events = pair.viewer.tick(pair.now + FRAME_TIMEOUT).unwrap();
        assert!(matches!(&events[..], [ViewerMediaEvent::Send(feedback), ViewerMediaEvent::Send(prepare)]
            if MediaFeedback::decode(&feedback.payload).unwrap() == MediaFeedback { kind: FeedbackKind::Expired, header }
                && MediaControl::read(prepare).unwrap().operation == MediaOperation::Prepare));
        assert!(pair.viewer.decoded(DecodeReceipt::Media(stream, 2)).unwrap().is_empty(), "a late callback cannot confirm the expired frame");
    }

    #[test]
    fn a_host_aborts_a_timed_out_first_transaction_before_any_stream_committed() {
        let mut pair = Pair::new();
        pair.host_receives(ViewerMedia::request());
        let deadline = pair.host.deadline().unwrap();
        assert_eq!(pair.host.expire(deadline - Duration::from_millis(1)), (0, Vec::new()));
        let (settled, controls) = pair.host.expire(deadline);
        assert_eq!(settled, 0);
        assert!(matches!(controls.as_slice(), [abort] if abort.operation == MediaOperation::Abort && abort.transport_epoch == Some(1)));
        pair.viewer_receives(controls.into_iter().next().unwrap());
        let events = pair.viewer.tick(pair.now + ViewerMedia::RETRY_DELAY).unwrap();
        pair.viewer_events(events);
        assert_eq!(pair.host.preparing().unwrap().transport_epoch, 2);
    }

    #[test]
    fn pending_decode_limits_bound_work_across_legacy_and_media_streams() {
        let mut viewer = ViewerMedia::default();
        viewer.legacy(1, ViewerMedia::MAXIMUM_PENDING_BYTES).unwrap();
        assert!(viewer.legacy(2, 1).is_err());
        viewer.decoded(DecodeReceipt::Legacy(1)).unwrap();
        for sequence in 0..ViewerMedia::MAXIMUM_PENDING_FRAMES as u32 {
            viewer.legacy(sequence, 10).unwrap();
        }
        assert!(viewer.legacy(10, 10).is_err());
        assert!(viewer.decoded(DecodeReceipt::Legacy(10)).unwrap().is_empty());
        viewer.decoded(DecodeReceipt::Legacy(0)).unwrap();
        viewer.legacy(10, 10).unwrap();
    }

    #[test]
    fn legacy_and_media_receipts_distinguish_reused_sequences() {
        let mut pair = Pair::new();
        pair.open();
        assert_eq!(pair.encode(8, dependent_frame()), "media");
        pair.viewer.legacy(8, 10).unwrap();
        let HostFrame::Media(reused) = pair.host.frame(8, dependent_frame()).unwrap() else { panic!("expected media frame") };
        assert!(pair.viewer.frame(&reused.payload, pair.now).is_err());
        assert!(matches!(pair.viewer.decoded(DecodeReceipt::Legacy(8)).unwrap().as_slice(), [ViewerMediaEvent::Send(message)]
            if message.kind == MessageKind::Acknowledgement));
        assert_eq!(pair.settled, 1);
        pair.decode(8);
        assert_eq!(pair.settled, 2);
    }

    #[test]
    fn a_missing_decoder_output_expires_without_charging_the_replacement_stream() {
        let mut pair = Pair::new();
        pair.open();
        for _ in 0..=ViewerMedia::MAXIMUM_PENDING_FRAMES {
            let retired = pair.viewer.active().unwrap();
            assert_eq!(pair.encode(2, dependent_frame()), "media");
            assert_eq!(pair.encode(3, dependent_frame()), "media");
            pair.decode(3);
            let events = pair.viewer.tick(pair.now + FRAME_TIMEOUT).unwrap();
            let [ViewerMediaEvent::Send(expired), ViewerMediaEvent::Send(prepare)] = events.as_slice() else { panic!("missing recovery request") };
            let expired = MediaFeedback::decode(&expired.payload).unwrap();
            assert_eq!((expired.kind, expired.header.frame_id), (FeedbackKind::Expired, 2));
            pair.host.feedback(&expired);
            pair.host_receives(MediaControl::read(prepare).unwrap());
            let ready = pair.host.prepared().unwrap();
            pair.viewer_receives(ready);
            assert_eq!(pair.encode(2, key_frame()), "media");
            assert!(pair.viewer.decoded(DecodeReceipt::Media(retired, 2)).unwrap().is_empty());
            pair.decode(2);
            assert_ne!(pair.viewer.active(), Some(retired));
        }
    }

    #[test]
    fn the_host_refuses_what_it_cannot_serve_and_the_viewer_asks_again() {
        let mut pair = Pair::new();
        pair.host.control(&ViewerMedia::request(), false).unwrap();
        let session = pair.host.session.unwrap();
        let named = |operation, transport_epoch, path: &str| {
            MediaControl::transaction(
                operation,
                Uuid::from_bytes([9; 16]),
                MediaStreamId { session_id: session, transport_epoch, codec_epoch: transport_epoch },
                path,
            )
        };
        let aborted = |events: Vec<HostMediaEvent>| matches!(&events[..], [HostMediaEvent::Send(control)] if control.operation == MediaOperation::Abort);
        assert!(aborted(pair.host.control(&named(MediaOperation::Prepare, 1, "tcp"), false).unwrap()), "no video connection was bound");
        assert!(aborted(pair.host.control(&named(MediaOperation::Prepare, 1, "udp"), false).unwrap()));
        assert!(aborted(pair.host.control(&named(MediaOperation::Prepare, 1, "shared"), true).unwrap()), "paused");
        assert!(aborted(pair.host.control(&named(MediaOperation::Prepare, 0, "shared"), false).unwrap()), "an epoch that is not newer");
        assert!(pair.host.control(&MediaControl { session_id: Some(Uuid::nil()), ..named(MediaOperation::Prepare, 1, "shared") }, false).unwrap().is_empty());
        assert!(
            pair.host
                .control(&MediaControl { role: Some("video".to_string()), token: Some(vec![0; 32]), ..MediaControl::new(MediaOperation::Bind) }, false)
                .is_err()
        );

        // The viewer's own exchange is refused by a paused host; it asks again half a second later.
        let offer = pair.host.offer().unwrap();
        let prepare = match &pair.viewer.control(&offer, pair.now).unwrap()[..] {
            [ViewerMediaEvent::Send(message)] => MediaControl::read(message).unwrap(),
            other => panic!("{other:?}"),
        };
        let refusal = match pair.host.control(&prepare, true).unwrap().pop() {
            Some(HostMediaEvent::Send(control)) => *control,
            other => panic!("{other:?}"),
        };
        assert!(pair.viewer.control(&refusal, pair.now).unwrap().is_empty());
        assert_eq!(pair.viewer.deadline(), Some(pair.now + Duration::from_millis(500)));
        assert!(pair.viewer.tick(pair.now + Duration::from_millis(499)).unwrap().is_empty());
        let again = pair.viewer.tick(pair.now + Duration::from_millis(500)).unwrap();
        let retry = match &again[..] {
            [ViewerMediaEvent::Send(message)] => MediaControl::read(message).unwrap(),
            other => panic!("{other:?}"),
        };
        assert_eq!((retry.operation, retry.transport_epoch), (MediaOperation::Prepare, Some(2)));

        // A host that never answers is given up on after eight seconds, then asked again.
        let started = pair.now + Duration::from_millis(500);
        let timed_out = pair.viewer.tick(started + Duration::from_secs(8)).unwrap();
        assert!(matches!(&timed_out[..], [ViewerMediaEvent::Send(message)] if MediaControl::read(message).unwrap().operation == MediaOperation::Abort));
        assert_eq!(pair.viewer.tick(started + Duration::from_millis(8500)).unwrap().len(), 1);
    }

    #[test]
    fn pausing_stops_the_exchange_and_resuming_opens_a_new_stream() {
        let mut pair = Pair::new();
        pair.open();
        let paused = pair.viewer.set_paused(true, pair.now).unwrap();
        assert!(paused.is_empty() && pair.viewer.deadline().is_none());
        assert!(pair.host.paused().is_none());
        let recover = MediaControl::recover(pair.viewer.active().unwrap());
        assert!(pair.viewer.control(&recover, pair.now).unwrap().is_empty(), "a paused viewer opens no stream");
        let resumed = pair.viewer.set_paused(false, pair.now).unwrap();
        assert!(matches!(&resumed[..], [ViewerMediaEvent::Send(message)] if MediaControl::read(message).unwrap().transport_epoch == Some(2)));
        // Pausing in the middle of an exchange tells the host to forget it.
        let aborted = pair.viewer.set_paused(true, pair.now).unwrap();
        assert!(matches!(&aborted[..], [ViewerMediaEvent::Send(message)] if MediaControl::read(message).unwrap().operation == MediaOperation::Abort));
    }

    #[test]
    fn a_stream_that_does_not_begin_with_frame_one_as_a_keyframe_is_replaced() {
        let mut pair = Pair::new();
        pair.open();
        let active = pair.viewer.active().unwrap();
        let skipped = MediaFrame::new(active, 5, VideoPacket::h264(8, dependent_frame())).unwrap().message().unwrap();
        let events = pair.viewer.frame(&skipped.payload, pair.now).unwrap();
        assert!(matches!(&events[..], [ViewerMediaEvent::Send(message)] if MediaControl::read(message).unwrap().operation == MediaOperation::Prepare));
        let repeated = MediaFrame::new(active, 1, VideoPacket::h264(1, key_frame())).unwrap().message().unwrap();
        assert!(pair.viewer.frame(&repeated.payload, pair.now).unwrap().is_empty());
        assert!(ViewerMedia::default().frame(&repeated.payload, pair.now).is_err(), "a frame before any session");
    }
}
