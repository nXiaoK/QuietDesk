//! Video as the macOS `MediaSession` frames it: stream identities, the
//! transaction that opens every stream with a keyframe the viewer has decoded, reliable frames, datagram fragments,
//! and the feedback that takes the place of legacy acknowledgements.
//!
//! A stream stays on its negotiated connection until a new keyframe transaction commits.

pub mod fragment;
mod path_policy;
use path_policy::UdpTrials;
pub mod window;

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
const MAXIMUM_FEEDBACK_BYTES: usize = fragment::MAX_RECORD_BYTES;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaPath {
    Shared,
    Tcp,
    Udp,
}

pub type ReliablePath = MediaPath;

impl MediaPath {
    fn name(self) -> &'static str {
        match self {
            Self::Shared => "shared",
            Self::Tcp => "tcp",
            Self::Udp => "udp",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct RoutedStream {
    stream: MediaStreamId,
    path: MediaPath,
}

impl RoutedStream {
    fn transaction(self, operation: MediaOperation, id: Uuid) -> MediaControl {
        MediaControl::transaction(operation, id, self.stream, self.path.name())
    }
}

const FRAME_TIMEOUT: Duration = Duration::from_secs(5);
const TRANSACTION_TIMEOUT: Duration = Duration::from_secs(8);
const UDP_VERIFICATION_GRACE: Duration = Duration::from_millis(350);

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
        Self::from_packet_bytes(header, reader.bytes(length)?)
    }

    fn from_packet_bytes(header: MediaFrameHeader, bytes: &[u8]) -> Result<Self> {
        let packet = VideoPacket::decode(bytes)?;
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FragmentRange {
    pub first: u16,
    pub count: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaFeedback {
    pub kind: FeedbackKind,
    pub header: MediaFrameHeader,
    missing: Vec<FragmentRange>,
}

impl MediaFeedback {
    pub fn new(kind: FeedbackKind, header: MediaFrameHeader) -> Result<Self> {
        Self::from_ranges(kind, header, Vec::new())
    }

    pub fn nack(header: MediaFrameHeader, ranges: Vec<FragmentRange>) -> Result<Self> {
        Self::from_ranges(FeedbackKind::Nack, header, ranges)
    }

    fn from_ranges(kind: FeedbackKind, header: MediaFrameHeader, ranges: Vec<FragmentRange>) -> Result<Self> {
        if ranges.len() > 64 || (kind == FeedbackKind::Nack) == ranges.is_empty() {
            return Err(DeskError::invalid("媒体反馈范围无效"));
        }
        let mut previous_end = 0;
        for range in &ranges {
            let first = u32::from(range.first);
            let end = first + u32::from(range.count);
            if range.count == 0 || first < previous_end || end > u32::from(u16::MAX) + 1 {
                return Err(DeskError::invalid("媒体缺片范围重复或溢出"));
            }
            previous_end = end;
        }
        Ok(Self { kind, header, missing: ranges })
    }

    pub fn missing_ranges(&self) -> &[FragmentRange] {
        &self.missing
    }

    pub fn message(&self) -> Message {
        let mut data = begin(FEEDBACK_RECORD, &self.header, 2 + self.missing.len() * 4);
        data.extend_from_slice(&[self.kind as u8, self.missing.len() as u8]);
        for range in &self.missing {
            data.extend_from_slice(&range.first.to_be_bytes());
            data.extend_from_slice(&range.count.to_be_bytes());
        }
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
        let count = usize::from(reader.u8()?);
        if count > 64 || reader.remaining() != count * 4 {
            return Err(DeskError::invalid("媒体反馈长度无效"));
        }
        let ranges = (0..count).map(|_| Ok(FragmentRange { first: reader.u16()?, count: reader.u16()? })).collect::<Result<_>>()?;
        Self::from_ranges(kind, header, ranges)
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

#[derive(Clone, Copy, Default)]
pub(crate) struct FragmentFeatures {
    pub marked_repairs: bool,
    pub xor: bool,
    pub block_limit: usize,
}

impl FragmentFeatures {
    pub fn from_peer(control: &MediaControl) -> Self {
        use fragment::fec::{LEGACY_PROTECTED_FRAGMENTS, MAX_PROTECTED_FRAGMENTS};
        let block_limit = if control.block_fec == Some(true) {
            control.fec_fragment_limit.unwrap_or(LEGACY_PROTECTED_FRAGMENTS as i64).clamp(2, MAX_PROTECTED_FRAGMENTS as i64) as usize
        } else {
            0
        };
        Self { marked_repairs: control.marked_repairs == Some(true), xor: control.parity_fec == Some(true), block_limit }
    }

    pub fn advertise(self, offer: &mut MediaControl) {
        offer.parity_fec = self.xor.then_some(true);
        offer.block_fec = (self.block_limit > 0).then_some(true);
    }
}

impl MediaControl {
    pub(crate) fn request_fragment_features(&mut self) {
        self.marked_repairs = Some(true);
        self.parity_fec = Some(true);
        self.block_fec = Some(true);
        self.fec_fragment_limit = Some(fragment::fec::MAX_PROTECTED_FRAGMENTS as i64);
    }

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
    AwaitingUdpVerification,
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
    fast: bool,
    needs_fresh_pong: bool,
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
    Datagram(MediaFrame),
    /// The frame belongs to no stream the viewer is receiving.
    Dropped,
}

/// The host's side of the session.
#[derive(Default)]
pub struct HostMedia {
    session: Option<Uuid>,
    credentials: Option<(Vec<u8>, Vec<u8>)>,
    datagram_interactive: bool,
    epochs: (u32, u32),
    transaction: Option<HostTransaction>,
    /// A commit sent before capture was interrupted can still be confirmed by the viewer.
    interrupted_commit: Option<(Uuid, RoutedStream)>,
    active: Option<RoutedStream>,
    video_bound: bool,
    udp_available: bool,
    udp_verified: bool,
    fast_recovery: bool,
    pub(crate) capture_limits: window::CaptureLimits,
    pub(crate) datagram_audio: bool,
    /// Frames wait for the viewer to open a new stream.
    hold: bool,
    next_frame: u64,
    /// Frames of the current stream the viewer has not reported as decoded.
    unsettled: VecDeque<OutstandingFrame>,
}

impl HostMedia {
    pub fn frame_path(&self) -> MediaPath {
        self.transaction.as_ref().map(|t| t.route).or(self.active).map_or(MediaPath::Shared, |r| r.path)
    }

    pub(crate) fn udp_frame_stream(&self) -> Option<MediaStreamId> {
        self.transaction
            .as_ref()
            .map(|tx| tx.route)
            .or(self.active.filter(|_| !self.hold))
            .filter(|route| route.path == MediaPath::Udp)
            .map(|route| route.stream)
    }

    pub fn set_video_bound(&mut self, bound: bool) -> (usize, Vec<MediaControl>) {
        let interrupted = self.video_bound && !bound && self.frame_path() == MediaPath::Tcp;
        self.video_bound = bound;
        if interrupted { self.interrupted() } else { (0, Vec::new()) }
    }

    /// Set before answering the first request, once the datagram listener can serve this session.
    pub fn set_udp_available(&mut self, available: bool) {
        self.udp_available = available;
    }

    pub fn set_udp_verified(&mut self, verified: bool) -> (usize, Vec<MediaControl>) {
        let interrupted = self.udp_verified && !verified && self.frame_path() == MediaPath::Udp;
        self.udp_verified = self.udp_available && verified;
        if let Some(transaction) = self.transaction.as_mut().filter(|tx| tx.stage == HostStage::AwaitingUdpVerification) {
            let now = Instant::now();
            if !self.udp_verified || now >= transaction.deadline {
                return self.interrupted();
            }
            transaction.stage = HostStage::Preparing;
            transaction.deadline = now + TRANSACTION_TIMEOUT;
        }
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
        Some(MediaControl {
            session_id: self.session,
            token: Some(token),
            fast_recovery: self.fast_recovery.then_some(true),
            datagram_interactive: self.datagram_interactive.then_some(true),
            datagram_key: Some(key),
            dynamic_frame_window: self.capture_limits.dynamic.then_some(true),
            path: Some(if self.udp_available { "udp" } else { "tcp" }.to_string()),
            ..MediaControl::new(MediaOperation::Offer)
        })
    }

    /// `paused` refuses new streams, as a paused macOS host does.
    pub fn control(&mut self, control: &MediaControl, paused: bool) -> Result<Vec<HostMediaEvent>> {
        self.control_with_datagram(control, paused, self.udp_verified)
    }

    pub(crate) fn control_with_datagram(&mut self, control: &MediaControl, paused: bool, udp_authenticated: bool) -> Result<Vec<HostMediaEvent>> {
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
                    self.fast_recovery = control.fast_recovery == Some(true);
                    self.datagram_interactive = control.datagram_interactive == Some(true);
                    self.credentials = Some((token, key));
                    self.capture_limits = window::CaptureLimits::from_request(control);
                    self.datagram_audio = control.datagram_audio == Some(true);
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
                Some(transaction) if matches!(transaction.stage, HostStage::Ready | HostStage::Producing | HostStage::Decoded) => {
                    vec![HostMediaEvent::Send(Box::new(MediaControl::transaction(Ready, id, stream, path)))]
                }
                Some(_) => Vec::new(),
                None if paused || stream.transport_epoch <= self.epochs.0 || stream.codec_epoch <= self.epochs.1 => refuse(),
                None => {
                    let path = match path {
                        "shared" => MediaPath::Shared,
                        "tcp" if self.video_bound => MediaPath::Tcp,
                        "udp" if self.udp_available && udp_authenticated => MediaPath::Udp,
                        _ => return Ok(refuse()),
                    };
                    let awaiting_udp = path == MediaPath::Udp && !self.udp_verified;
                    let fast = self.fast_recovery && control.fast == Some(true);
                    if fast && !self.active.iter().chain(self.interrupted_commit.iter().map(|(_, route)| route)).any(|route| route.path == path) {
                        return Ok(refuse());
                    }
                    self.epochs = (stream.transport_epoch, stream.codec_epoch);
                    self.interrupted_commit = None;
                    self.hold = true;
                    self.transaction = Some(HostTransaction {
                        id,
                        route: RoutedStream { stream, path },
                        stage: if awaiting_udp { HostStage::AwaitingUdpVerification } else { HostStage::Preparing },
                        key_frame_sent: false,
                        fast,
                        needs_fresh_pong: fast && path == MediaPath::Udp,
                        deadline: Instant::now() + if awaiting_udp { UDP_VERIFICATION_GRACE } else { TRANSACTION_TIMEOUT },
                    });
                    self.next_frame = 1;
                    let settled = std::mem::take(&mut self.unsettled).len();
                    let mut events = vec![HostMediaEvent::Settled(settled)];
                    if !awaiting_udp {
                        events.push(HostMediaEvent::Prepare(stream));
                    }
                    events
                }
            },
            Ready => match current {
                Some(transaction) if !transaction.fast && transaction.stage == HostStage::Ready => {
                    transaction.stage = HostStage::Producing;
                    vec![HostMediaEvent::ProduceKeyFrame]
                }
                _ => Vec::new(),
            },
            DecodedReady => match current {
                Some(transaction) if !transaction.fast && transaction.key_frame_sent => {
                    transaction.stage = HostStage::Decoded;
                    // This confirmation stands for the keyframe's own feedback, which may still be on its way.
                    let settled = self.unsettled.iter().take_while(|frame| frame.header.frame_id == 1).count();
                    self.unsettled.drain(..settled);
                    vec![HostMediaEvent::Settled(settled), HostMediaEvent::Send(Box::new(MediaControl::transaction(Commit, id, stream, path)))]
                }
                _ => Vec::new(),
            },
            Committed => match current {
                Some(transaction)
                    if transaction.fast && transaction.key_frame_sent && transaction.stage == HostStage::Producing && Instant::now() < transaction.deadline =>
                {
                    self.commit_fast();
                    vec![HostMediaEvent::Settled(std::mem::take(&mut self.unsettled).len())]
                }
                Some(transaction) if transaction.stage == HostStage::Decoded => {
                    self.active = Some(transaction.route);
                    self.transaction = None;
                    self.hold = false;
                    log::info!("host committed {path} media stream (transport epoch {}, codec epoch {})", stream.transport_epoch, stream.codec_epoch);
                    Vec::new()
                }
                None if self.interrupted_commit.is_some_and(|(pending, route)| pending == id && route.stream == stream && route.path.name() == path) => {
                    self.active = self.interrupted_commit.take().map(|(_, route)| route);
                    if paused { Vec::new() } else { self.recovery().map(|recover| HostMediaEvent::Send(Box::new(recover))).into_iter().collect() }
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

    pub(crate) fn interactive_datagrams(&self) -> bool {
        self.datagram_interactive && self.udp_verified && self.frame_path() == MediaPath::Udp && (!self.hold || self.transaction.is_some())
    }

    pub(crate) fn fast_recovery_negotiated(&self) -> bool {
        self.fast_recovery
    }

    pub(crate) fn accepts_fast_copy(&self, control: &MediaControl) -> bool {
        if control.operation != MediaOperation::Prepare
            || control.fast != Some(true)
            || control.path.as_deref() != Some("udp")
            || control.session_id != self.session
        {
            return false;
        }
        // An old UDP copy cannot invalidate the control channel's newer transaction.
        self.transaction.as_ref().is_none_or(|tx| {
            Some(tx.id) != control.transaction_id
                || (tx.route.path == MediaPath::Udp
                    && Some(tx.route.stream.transport_epoch) == control.transport_epoch
                    && Some(tx.route.stream.codec_epoch) == control.codec_epoch)
        })
    }

    pub(crate) fn pending_fast_challenge(&self) -> Option<Uuid> {
        self.transaction.as_ref().filter(|t| t.needs_fresh_pong).map(|t| t.id)
    }

    pub(crate) fn answered_fast_challenge(&mut self, id: Uuid) {
        if let Some(tx) = self.transaction.as_mut().filter(|tx| tx.id == id) {
            tx.needs_fresh_pong = false;
        }
    }

    pub(crate) fn take_fast_keyframe(&mut self) -> bool {
        let Some(tx) = self.transaction.as_mut().filter(|tx| tx.fast && !tx.needs_fresh_pong && tx.stage == HostStage::Ready && Instant::now() < tx.deadline)
        else {
            return false;
        };
        tx.stage = HostStage::Producing;
        true
    }

    pub(crate) fn fast_opening(&self) -> Option<MediaFrameHeader> {
        self.transaction.as_ref().filter(|tx| tx.fast && tx.key_frame_sent && tx.stage == HostStage::Producing).map(|tx| MediaFrameHeader {
            stream: tx.route.stream,
            frame_id: 1,
            is_idr: true,
        })
    }

    fn commit_fast(&mut self) {
        let tx = self.transaction.take().expect("confirmed fast recovery");
        self.active = Some(tx.route);
        self.hold = false;
        log::info!("host committed fast {} media stream (transport epoch {})", tx.route.path.name(), tx.route.stream.transport_epoch);
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
        let route = match &self.transaction {
            Some(transaction) if transaction.stage == HostStage::Producing && !transaction.key_frame_sent && frame.is_key_frame() => transaction.route,
            Some(_) => return Ok(HostFrame::Dropped),
            None if self.hold => return Ok(HostFrame::Dropped),
            None => match self.active {
                Some(route) => route,
                None => return Ok(HostFrame::Legacy(VideoPacket::h264(sequence, frame))),
            },
        };
        let frame = MediaFrame::new(route.stream, self.next_frame, VideoPacket::h264(sequence, frame))?;
        let header = frame.header;
        let output = if route.path == MediaPath::Udp { HostFrame::Datagram(frame) } else { HostFrame::Media(frame.message()?) };
        self.next_frame = self.next_frame.checked_add(1).ok_or_else(|| DeskError::Network("媒体帧序号已耗尽，需要重新连接".to_string()))?;
        if let Some(transaction) = &mut self.transaction {
            transaction.key_frame_sent = true;
        }
        self.unsettled.push_back(OutstandingFrame { header, deadline: Instant::now() + FRAME_TIMEOUT, reassembled: false });
        Ok(output)
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
                if self.fast_opening() == Some(feedback.header) {
                    self.commit_fast();
                }
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
        let aborted = self.abort_transaction();
        self.hold = self.hold || self.active.is_some() || aborted.is_some();
        let settled = std::mem::take(&mut self.unsettled).len();
        (settled, aborted.into_iter().chain(self.recovery()).collect())
    }

    /// Stops the exchange in progress; a paused host opens no stream.
    pub fn paused(&mut self) -> Option<MediaControl> {
        self.abort_transaction()
    }

    fn abort_transaction(&mut self) -> Option<MediaControl> {
        let transaction = self.transaction.take()?;
        if transaction.stage == HostStage::Decoded || (transaction.fast && transaction.key_frame_sent) {
            self.interrupted_commit = Some((transaction.id, transaction.route));
        }
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

const FAST_REQUEST_INTERVAL: Duration = Duration::from_millis(50);
const MAX_FAST_REQUESTS: u8 = 20;

struct FastReceive {
    host_ready: bool,
    held: Option<VideoPacket>,
    sends: u8,
    repeat_at: Option<Instant>,
}

struct ViewerTransaction {
    id: Uuid,
    route: RoutedStream,
    stage: ViewerStage,
    fast: Option<FastReceive>,
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
    reported_playback: bool,
}

impl ReceivingStream {
    fn new(stream: MediaStreamId) -> Self {
        Self { stream, next_frame: 1, pending: VecDeque::new(), last_decoded: None, reported_playback: false }
    }
}

#[derive(Debug)]
pub enum ViewerMediaEvent {
    Send(Message),
    DatagramFeedback(MediaFeedback),
    DatagramPrepare(Vec<u8>),
    /// A frame to decode and whether the host needs its decoded receipt before sending another.
    Video(VideoPacket, MediaStreamId, bool),
    /// Frames of this stream are now what the viewer shows.
    Committed(MediaStreamId),
}

impl ViewerMediaEvent {
    fn feedback(path: MediaPath, kind: FeedbackKind, header: MediaFrameHeader) -> Self {
        let feedback = MediaFeedback { kind, header, missing: Vec::new() };
        if path == MediaPath::Udp { Self::DatagramFeedback(feedback) } else { Self::Send(feedback.message()) }
    }
}

/// The viewer's side of the session. The viewer decides when a stream is opened.
#[derive(Default)]
pub struct ViewerMedia {
    udp_trials: UdpTrials,
    datagram_interactive: bool,
    session: Option<Uuid>,
    epochs: (u32, u32),
    transaction: Option<ViewerTransaction>,
    active: Option<RoutedStream>,
    video_bound: bool,
    udp_available: bool,
    fragments: FragmentFeatures,
    fast_recovery: bool,
    dynamic_window: bool,
    datagram_audio: bool,
    udp_verified: bool,
    receiving: Option<ReceivingStream>,
    auxiliary_enabled: bool,
    legacy_decodes: VecDeque<(u32, usize)>,
    retry_at: Option<Instant>,
    paused: bool,
}

impl ViewerMedia {
    const RETRY_DELAY: Duration = Duration::from_millis(500);

    /// Asks the host for a session. No optional capability is named, so the host uses none.
    pub fn request() -> MediaControl {
        MediaControl::new(MediaOperation::Request)
    }

    pub(crate) fn request_datagram_audio(&mut self, request: &mut MediaControl) {
        self.datagram_audio = true;
        request.datagram_audio = Some(true);
    }

    pub(crate) fn receives_datagram_audio(&self) -> bool {
        self.datagram_audio && self.udp_verified
    }

    pub(crate) fn request_dynamic_window(&mut self, request: &mut MediaControl) {
        self.dynamic_window = true;
        request.dynamic_frame_window = Some(true);
        request.receive_frame_window = Some(window::STATIC_FRAMES as i64);
    }

    pub(crate) fn receive_capacity(&self) -> usize {
        if self.session.is_some() && self.dynamic_window { window::MAX_DYNAMIC_FRAMES } else { window::STATIC_FRAMES }
    }

    pub(crate) fn accepts_fec(&self, kind: u8) -> bool {
        self.udp_available
            && match kind {
                fragment::fec::XOR_KIND => self.fragments.xor,
                fragment::fec::BLOCK_KIND => self.fragments.block_limit > 0,
                _ => false,
            }
    }

    pub(crate) fn has_offer(&self) -> bool {
        self.session.is_some()
    }

    pub fn active(&self) -> Option<MediaStreamId> {
        self.active.map(|route| route.stream)
    }

    pub(crate) fn udp_verified(&self) -> bool {
        self.udp_verified
    }

    pub fn frame_path(&self) -> MediaPath {
        self.transaction.as_ref().map(|t| t.route).or(self.active).map_or(MediaPath::Shared, |r| r.path)
    }

    pub fn receiving_stream(&self) -> Option<MediaStreamId> {
        self.receiving.as_ref().map(|receiver| receiver.stream)
    }

    /// Set before consuming the offer, once the endpoint and the local transport are available.
    pub fn set_udp_available(&mut self, available: bool) {
        self.udp_available = available;
    }

    pub fn set_udp_verified(&mut self, verified: bool, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if !self.udp_available || self.udp_verified == verified {
            return Ok(Vec::new());
        }
        self.udp_verified = verified;
        self.udp_trials = UdpTrials::default();
        if !verified && self.frame_path() == MediaPath::Udp {
            self.restart(now)
        } else if verified && self.transaction.is_none() && self.frame_path() != MediaPath::Udp {
            self.begin(now)
        } else {
            if !verified && self.receiving.is_some() && self.transaction.is_none() {
                self.retry_at = None;
            }
            Ok(Vec::new())
        }
    }

    pub(crate) fn request_interactive(&mut self, request: &mut MediaControl) {
        self.datagram_interactive = true;
        request.datagram_interactive = Some(true);
    }

    pub(crate) fn interactive_datagrams(&self) -> bool {
        self.datagram_interactive
            && self.udp_verified
            && !self.paused
            && self.frame_path() == MediaPath::Udp
            && (self.receiving.is_some() || self.transaction.is_some())
    }

    pub(crate) fn request_fast_recovery(&mut self, request: &mut MediaControl) {
        self.fast_recovery = true;
        request.fast_recovery = Some(true);
    }

    pub fn enable_auxiliary(&mut self) {
        self.auxiliary_enabled = true;
    }

    /// An expired reference chain may be retried on a live path. Keep the last displayed picture during the retry.
    pub(crate) fn udp_delivery_failed(&mut self, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if !self.udp_verified || self.frame_path() != MediaPath::Udp || self.receiving.is_none() && self.transaction.is_none() {
            return Ok(Vec::new());
        }
        let retry = if self.transaction.is_some() { self.udp_trials.retry_opener() } else { self.udp_trials.retry_playback(now) };
        if !retry {
            return self.set_udp_verified(false, now);
        }
        let abort = self.abandon().map(|control| control.message().map(ViewerMediaEvent::Send)).transpose()?;
        self.retry_at = Some(now + Duration::from_secs(1));
        Ok(abort.into_iter().collect())
    }

    pub fn set_video_bound(&mut self, bound: bool, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if !self.auxiliary_enabled || self.video_bound == bound {
            return Ok(Vec::new());
        }
        self.video_bound = bound;
        if !bound && self.frame_path() == MediaPath::Tcp {
            self.restart(now)
        } else if bound && !self.udp_available && self.active.is_none() && self.transaction.is_none() {
            self.begin(now)
        } else {
            Ok(Vec::new())
        }
    }

    fn restart(&mut self, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        let mut events: Vec<_> = self.abandon().map(|abort| abort.message().map(ViewerMediaEvent::Send)).transpose()?.into_iter().collect();
        events.extend(self.begin(now)?);
        Ok(events)
    }

    fn begin(&mut self, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        let Some(session_id) = self.session.filter(|_| !self.paused && self.transaction.is_none()) else { return Ok(Vec::new()) };
        if self.epochs.0 == u32::MAX || self.epochs.1 == u32::MAX {
            return Err(DeskError::Network("媒体会话代次已耗尽，需要重新连接".to_string()));
        }
        self.epochs = (self.epochs.0 + 1, self.epochs.1 + 1);
        let stream = MediaStreamId { session_id, transport_epoch: self.epochs.0, codec_epoch: self.epochs.1 };
        let path = if self.udp_verified {
            MediaPath::Udp
        } else if self.video_bound {
            MediaPath::Tcp
        } else {
            MediaPath::Shared
        };
        let fast = self.fast_recovery && self.active.is_some_and(|active| active.path == path);
        let transaction = ViewerTransaction {
            id: Uuid::new_v4(),
            route: RoutedStream { stream, path },
            stage: if fast { ViewerStage::Ready } else { ViewerStage::Preparing },
            fast: fast.then_some(FastReceive { host_ready: false, held: None, sends: 0, repeat_at: (path == MediaPath::Udp).then_some(now) }),
            started: now,
        };
        let mut prepare = transaction.route.transaction(MediaOperation::Prepare, transaction.id);
        prepare.fast = fast.then_some(true);
        self.receiving = fast.then(|| ReceivingStream::new(stream));
        self.transaction = Some(transaction);
        self.retry_at = None;
        let mut events = vec![ViewerMediaEvent::Send(prepare.message()?)];
        events.extend(self.fast_prepare(now)?);
        Ok(events)
    }

    fn fast_prepare(&mut self, now: Instant) -> Result<Option<ViewerMediaEvent>> {
        let Some(tx) = self.transaction.as_mut() else { return Ok(None) };
        let Some(fast) = tx.fast.as_mut().filter(|f| f.repeat_at.is_some_and(|at| now >= at)) else { return Ok(None) };
        let mut copy = tx.route.transaction(MediaOperation::Prepare, tx.id);
        copy.fast = Some(true);
        let mut record = vec![11];
        record.extend(copy.message()?.payload);
        fast.sends += 1;
        fast.repeat_at = (fast.sends < MAX_FAST_REQUESTS).then_some(now + FAST_REQUEST_INTERVAL);
        Ok(Some(ViewerMediaEvent::DatagramPrepare(record)))
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
                self.fragments = FragmentFeatures::from_peer(control);
                self.fast_recovery &= control.fast_recovery == Some(true);
                self.datagram_interactive &= control.datagram_interactive == Some(true);
                self.dynamic_window &= control.dynamic_frame_window == Some(true);
                self.datagram_audio &= control.datagram_audio == Some(true);
                self.udp_available &= control.path.as_deref() != Some("tcp");
                self.udp_verified &= self.udp_available;
                if !self.udp_verified && (self.udp_available || (self.auxiliary_enabled && !self.video_bound)) {
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
                return if current == Some(named) && self.retry_at.is_none() { self.begin(now) } else { Ok(Vec::new()) };
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
            (Ready, _) if transaction.fast.is_some() => {
                let fast = transaction.fast.as_mut().unwrap();
                fast.host_ready = true;
                fast.repeat_at = None;
                fast.held.take().map(|packet| ViewerMediaEvent::Video(packet, stream, true)).into_iter().collect()
            }
            (Ready, ViewerStage::Preparing) => {
                transaction.stage = ViewerStage::Ready;
                self.receiving = Some(ReceivingStream::new(stream));
                vec![ViewerMediaEvent::Send(MediaControl::transaction(Ready, id, stream, path).message()?)]
            }
            (Commit, ViewerStage::Decoded) if transaction.fast.is_none() => self.commit(now)?,
            (Abort, _) => {
                if transaction.route.path == MediaPath::Udp && transaction.stage != ViewerStage::Preparing {
                    return self.udp_delivery_failed(now);
                }
                if transaction.route.path == MediaPath::Udp {
                    self.udp_verified = false;
                }
                self.abandon();
                self.retry_at = Some(now + Self::RETRY_DELAY);
                Vec::new()
            }
            _ => Vec::new(),
        })
    }

    fn commit(&mut self, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        let tx = self.transaction.take().expect("decoded opening stream");
        let route = tx.route;
        if route.path == MediaPath::Udp {
            self.udp_trials.opened();
        }
        self.active = Some(route);
        if self.udp_verified && route.path != MediaPath::Udp {
            self.retry_at = Some(now + Self::RETRY_DELAY);
        }
        log::info!(
            "viewer committed {} media stream (transport epoch {}, codec epoch {})",
            route.path.name(),
            route.stream.transport_epoch,
            route.stream.codec_epoch
        );
        Ok(vec![ViewerMediaEvent::Committed(route.stream), ViewerMediaEvent::Send(route.transaction(MediaOperation::Committed, tx.id).message()?)])
    }

    pub fn frame(&mut self, payload: &[u8], now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        self.frame_on(MediaPath::Shared, payload, now)
    }

    pub fn frame_on(&mut self, path: MediaPath, payload: &[u8], now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if self.session.is_none() {
            return Err(DeskError::invalid("媒体帧会话尚未协商"));
        }
        if self.frame_path() != path || path == MediaPath::Udp {
            return Ok(Vec::new());
        }
        self.accept_frame(MediaFrame::decode(payload)?, true, now)
    }

    /// The fragment receiver already validated the stream payload and sent its arrival feedback.
    pub fn assembled_frame(&mut self, frame: MediaFrame, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if self.frame_path() != MediaPath::Udp {
            return Ok(Vec::new());
        }
        self.accept_frame(frame, false, now)
    }

    fn accept_frame(&mut self, frame: MediaFrame, report_arrival: bool, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        let Some(receiver) = self.receiving.as_ref().filter(|receiver| receiver.stream == frame.header.stream) else { return Ok(Vec::new()) };
        let expected = receiver.next_frame;
        if frame.header.frame_id < expected {
            return Ok(receiver.last_decoded.map(|header| ViewerMediaEvent::feedback(self.frame_path(), FeedbackKind::Decoded, header)).into_iter().collect());
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
        let bytes = frame.packet.encoded_len();
        self.check_decode_capacity(bytes)?;
        let receiver = self.receiving.as_mut().expect("the frame belongs to this receiver");
        receiver.pending.push_back(PendingMediaDecode {
            sequence: frame.packet.sequence,
            header: frame.header,
            deadline: now + FRAME_TIMEOUT,
            decoded: false,
            bytes,
        });
        receiver.next_frame += 1;
        let mut events = Vec::new();
        if report_arrival {
            events.push(ViewerMediaEvent::feedback(self.frame_path(), FeedbackKind::Reassembled, frame.header));
        }
        if let Some(fast) = self.transaction.as_mut().and_then(|tx| tx.fast.as_mut()).filter(|f| !f.host_ready) {
            fast.held = Some(frame.packet);
            fast.repeat_at = None;
        } else {
            events.push(ViewerMediaEvent::Video(frame.packet, frame.header.stream, frame.header.frame_id == 1));
        }
        Ok(events)
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
        if count >= self.receive_capacity() || bytes > window::MAX_BUFFERED_BYTES - used {
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
        if self.transaction.as_ref().and_then(|tx| tx.fast.as_ref()).is_some_and(|f| f.held.is_some()) {
            return Ok(Vec::new());
        }
        let timed_events = self.tick(Instant::now())?;
        if !timed_events.is_empty() {
            return Ok(timed_events);
        }
        let path = self.frame_path();
        let Some(receiver) = self.receiving.as_mut().filter(|receiver| receiver.stream == stream) else { return Ok(Vec::new()) };
        let Some(frame) = receiver.pending.iter_mut().find(|pending| pending.sequence == sequence) else { return Ok(Vec::new()) };
        frame.decoded = true;
        // Feedback is cumulative. A later output must wait for every preceding picture.
        let complete = receiver.pending.iter().take_while(|pending| pending.decoded).count();
        let Some(last) = receiver.pending.drain(..complete).next_back() else { return Ok(Vec::new()) };
        let header = last.header;
        receiver.last_decoded = Some(header);
        if !header.is_idr && header.frame_id >= 8 && !receiver.reported_playback {
            receiver.reported_playback = true;
            log::info!("viewer decoded continuous {} video (transport epoch {}, through frame {})", path.name(), stream.transport_epoch, header.frame_id);
        }
        let mut events = vec![ViewerMediaEvent::feedback(path, FeedbackKind::Decoded, header)];
        if let Some(transaction) = self.transaction.as_mut().filter(|transaction| transaction.stage == ViewerStage::Ready) {
            transaction.stage = ViewerStage::Decoded;
            if transaction.fast.is_some() {
                events.extend(self.commit(Instant::now())?);
            } else {
                events.push(ViewerMediaEvent::Send(transaction.route.transaction(MediaOperation::DecodedReady, transaction.id).message()?));
            }
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
            .chain(self.transaction.as_ref().and_then(|tx| tx.fast.as_ref()?.repeat_at))
            .min()
    }

    fn awaiting_decode(&self) -> Option<(MediaFrameHeader, Instant)> {
        self.receiving.as_ref()?.pending.front().map(|frame| (frame.header, frame.deadline))
    }

    pub fn tick(&mut self, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        let mut events = Vec::new();
        if let Some((header, _)) = self.awaiting_decode().filter(|(_, deadline)| now >= *deadline) {
            events.push(ViewerMediaEvent::feedback(self.frame_path(), FeedbackKind::Expired, header));
            if self.frame_path() == MediaPath::Udp {
                events.extend(self.udp_delivery_failed(now)?);
            } else if self.transaction.as_ref().is_some_and(|pending| pending.route.stream == header.stream) {
                events.extend(self.abandon().map(|abort| abort.message().map(ViewerMediaEvent::Send)).transpose()?);
                self.retry_at = Some(now + Self::RETRY_DELAY);
            } else {
                events.extend(self.begin(now)?);
            }
        } else if self.transaction.as_ref().is_some_and(|transaction| now >= transaction.started + TRANSACTION_TIMEOUT) {
            if self.frame_path() == MediaPath::Udp {
                return self.udp_delivery_failed(now);
            }
            events.extend(self.abandon().map(|abort| abort.message().map(ViewerMediaEvent::Send)).transpose()?);
            self.retry_at = Some(now + Self::RETRY_DELAY);
        } else if self.retry_at.is_some_and(|at| now >= at) {
            self.retry_at = None;
            events.extend(self.begin(now)?);
        } else {
            events.extend(self.fast_prepare(now)?);
        }
        Ok(events)
    }

    /// A paused session opens no stream; a resumed one opens a new one at once.
    pub fn set_paused(&mut self, paused: bool, now: Instant) -> Result<Vec<ViewerMediaEvent>> {
        if self.paused == paused {
            return Ok(Vec::new());
        }
        self.paused = paused;
        self.udp_trials = UdpTrials::default();
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

    #[test]
    fn fec_negotiation_keeps_the_first_offer_and_respects_older_receiver_limits() {
        use fragment::fec::{BLOCK_KIND, XOR_KIND};
        let mut request = ViewerMedia::request();
        let old = FragmentFeatures::from_peer(&request);
        assert!(!old.xor && old.block_limit == 0);
        request.block_fec = Some(true);
        assert_eq!(FragmentFeatures::from_peer(&request).block_limit, 256);
        request.fec_fragment_limit = Some(i64::MAX);
        assert_eq!(FragmentFeatures::from_peer(&request).block_limit, 4096);
        request.fec_fragment_limit = Some(12);
        assert_eq!(FragmentFeatures::from_peer(&request).block_limit, 12);
        request.request_fragment_features();
        assert_eq!(request.fec_fragment_limit, Some(4096));
        let mut host = HostMedia::default();
        host.set_udp_available(true);
        let Some(HostMediaEvent::Send(mut offer)) = host.control(&request, false).unwrap().pop() else { panic!("expected offer") };
        request.block_fec = None;
        FragmentFeatures::from_peer(&request).advertise(&mut offer);
        let mut viewer = ViewerMedia::default();
        viewer.set_udp_available(true);
        viewer.control(&offer, Instant::now()).unwrap();
        assert!(viewer.accepts_fec(XOR_KIND));
        assert!(!viewer.accepts_fec(BLOCK_KIND));
        offer.block_fec = Some(true);
        viewer.control(&offer, Instant::now()).unwrap();
        assert!(!viewer.accepts_fec(BLOCK_KIND));
        let mut disabled = ViewerMedia::default();
        disabled.control(&offer, Instant::now()).unwrap();
        assert!(!disabled.accepts_fec(XOR_KIND));
    }

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
        let message = MediaFeedback { missing: Vec::new(), kind: FeedbackKind::Decoded, header }.message();
        assert_eq!(message.payload.len(), 39);
        assert_eq!(message.payload[..4], [0x51, 0x4D, 1, 3]);
        assert_eq!(message.payload[36..], [0, 2, 0]);
        assert_eq!(MediaFeedback::decode(&message.payload).unwrap(), MediaFeedback { missing: Vec::new(), kind: FeedbackKind::Decoded, header });
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
                    ViewerMediaEvent::DatagramPrepare(_) => {}
                    ViewerMediaEvent::DatagramFeedback(feedback) => {
                        let (settled, controls) = self.host.feedback(&feedback);
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
                HostFrame::Datagram(frame) => {
                    let events = self.viewer.assembled_frame(frame, self.now).unwrap();
                    self.viewer_events(events);
                    "udp"
                }
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

        fn offer_udp(&mut self) {
            self.host.set_udp_available(true);
            self.viewer.set_udp_available(true);
            self.viewer.enable_auxiliary();
            self.host_receives(ViewerMedia::request());
        }

        fn verify_udp(&mut self) {
            assert_eq!(self.host.set_udp_verified(true), (0, Vec::new()));
            let events = self.viewer.set_udp_verified(true, self.now).unwrap();
            self.viewer_events(events);
        }

        fn early_udp_prepare(&mut self) -> MediaControl {
            self.offer_udp();
            self.bind_video();
            let events = self.viewer.set_udp_verified(true, self.now).unwrap();
            let [ViewerMediaEvent::Send(request)] = events.as_slice() else { panic!("expected UDP prepare") };
            let request = MediaControl::read(request).unwrap();
            assert_eq!(self.host.control_with_datagram(&request, false, true).unwrap(), [HostMediaEvent::Settled(0)]);
            request
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
    fn a_verified_datagram_stream_starts_with_one_reassembled_keyframe_and_one_decode_ack() {
        let mut pair = Pair::new();
        pair.offer_udp();
        pair.bind_video();
        assert_eq!(pair.viewer.deadline(), Some(pair.now + Duration::from_millis(1500)));
        assert!(pair.prepared.is_empty());
        pair.verify_udp();
        assert_eq!((pair.host.frame_path(), pair.viewer.frame_path()), (MediaPath::Udp, MediaPath::Udp));
        assert!(pair.viewer.receiving_stream().is_none());
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        let HostFrame::Datagram(frame) = pair.host.frame(1, key_frame()).unwrap() else { panic!("expected a datagram frame") };
        let header = frame.header;
        assert_eq!(pair.viewer.receiving_stream(), Some(header.stream));
        let encoded = frame.message().unwrap();
        for path in [MediaPath::Shared, MediaPath::Tcp, MediaPath::Udp] {
            assert!(pair.viewer.frame_on(path, &encoded.payload, pair.now).unwrap().is_empty());
        }
        let events = pair.viewer.assembled_frame(frame, pair.now).unwrap();
        assert!(matches!(events.as_slice(), [ViewerMediaEvent::Video(_, _, true)]));
        pair.viewer_events(events);
        let decoded = pair.viewer.decoded(DecodeReceipt::Media(header.stream, 1)).unwrap();
        assert!(matches!(decoded.as_slice(), [ViewerMediaEvent::DatagramFeedback(ack), ViewerMediaEvent::Send(ready)] if
            *ack == MediaFeedback::new(FeedbackKind::Decoded, header).unwrap()
            && MediaControl::read(ready).unwrap().operation == MediaOperation::DecodedReady));
        pair.viewer_events(decoded);
        assert_eq!((pair.host.gate(), pair.settled), (Gate::Open, 1));
        assert_eq!(pair.encode(2, dependent_frame()), "udp");
    }

    #[test]
    fn an_unverified_host_refuses_udp_and_a_retry_on_bound_tcp_opens_normally() {
        let mut pair = Pair::new();
        pair.offer_udp();
        pair.bind_video();
        let events = pair.viewer.set_udp_verified(true, pair.now).unwrap();
        pair.viewer_events(events);
        assert!(pair.prepared.is_empty());
        assert_eq!(pair.log.last(), Some(&("host", MediaOperation::Abort)));
        assert_eq!(pair.host.gate(), Gate::Open);
        let deadline = pair.viewer.deadline().unwrap();
        let events = pair.viewer.tick(deadline).unwrap();
        pair.viewer_events(events);
        assert_eq!(pair.prepared.len(), 1);
        assert_eq!(pair.host.frame_path(), MediaPath::Tcp);
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(1, key_frame()), "media");
        pair.decode(1);
        assert_eq!(pair.host.gate(), Gate::Open);
    }

    #[tokio::test(start_paused = true)]
    async fn an_authenticated_udp_prepare_waits_for_the_local_probe_before_opening_the_encoder() {
        let mut pair = Pair::new();
        let prepare = pair.early_udp_prepare();
        let deadline = pair.host.deadline().unwrap();
        tokio::time::advance(Duration::from_millis(349)).await;
        assert!(pair.host.control_with_datagram(&prepare, false, true).unwrap().is_empty());
        assert_eq!(pair.host.deadline(), Some(deadline));
        assert!(pair.host.prepared().is_none());
        assert_eq!(pair.host.gate(), Gate::Closed);
        assert!(matches!(pair.host.frame(1, key_frame()).unwrap(), HostFrame::Dropped));

        assert_eq!(pair.host.set_udp_verified(true), (0, vec![]));
        let opening = pair.host.preparing().unwrap();
        let ready = pair.host.prepared().unwrap();
        assert_eq!(ready.transaction_id, prepare.transaction_id);
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(2, key_frame()), "udp");
        let decoded = pair.viewer.decoded(DecodeReceipt::Media(opening, 2)).unwrap();
        pair.viewer_events(decoded);
        assert_eq!(pair.encode(3, dependent_frame()), "udp");
    }

    #[tokio::test(start_paused = true)]
    async fn an_expired_udp_prepare_aborts_even_when_verification_wakes_first() {
        for verification_wakes_first in [true, false] {
            let mut pair = Pair::new();
            let prepare = pair.early_udp_prepare();
            tokio::time::advance(Duration::from_millis(350)).await;
            let (_, replies) = if verification_wakes_first { pair.host.set_udp_verified(true) } else { pair.host.expire(Instant::now()) };
            let [abort] = replies.as_slice() else { panic!("expected one abort") };
            assert_eq!((abort.operation, abort.transaction_id), (MediaOperation::Abort, prepare.transaction_id));
            assert_eq!(pair.host.set_udp_verified(true), (0, vec![]));
            assert!(pair.host.prepared().is_none());
            pair.viewer_receives(abort.clone());
            let events = pair.viewer.tick(pair.viewer.deadline().unwrap()).unwrap();
            pair.viewer_events(events);
            let ready = pair.host.prepared().unwrap();
            pair.viewer_receives(ready);
            assert_eq!(pair.encode(1, key_frame()), "media");
            pair.decode(1);
            assert_eq!(pair.host.frame_path(), MediaPath::Tcp);
        }
    }

    #[test]
    fn fallback_after_probe_timeout_uses_the_available_reliable_route_and_finishes_its_cutover() {
        for bound in [false, true] {
            let mut pair = Pair::new();
            pair.offer_udp();
            if bound {
                pair.bind_video();
            }
            let deadline = pair.viewer.deadline().unwrap();
            assert_eq!(deadline, pair.now + Duration::from_millis(1500));
            assert!(pair.viewer.tick(deadline - Duration::from_millis(1)).unwrap().is_empty());
            let events = pair.viewer.tick(deadline).unwrap();
            pair.viewer_events(events);
            let chosen = if bound { MediaPath::Tcp } else { MediaPath::Shared };
            assert_eq!(pair.host.frame_path(), chosen);
            pair.verify_udp();
            assert_eq!(pair.viewer.frame_path(), chosen);
            assert_eq!(pair.prepared.len(), 1);
            let ready = pair.host.prepared().unwrap();
            pair.viewer_receives(ready);
            assert_eq!(pair.encode(1, key_frame()), "media");
            pair.decode(1);
            assert_eq!(pair.host.gate(), Gate::Open);
            let upgrade_at = pair.viewer.deadline().unwrap();
            let events = pair.viewer.tick(upgrade_at).unwrap();
            pair.viewer_events(events);
            assert_eq!(pair.host.frame_path(), MediaPath::Udp);
        }
    }

    #[test]
    fn a_tcp_only_offer_disables_datagrams_even_if_the_viewer_has_a_route() {
        let mut pair = Pair::new();
        pair.viewer.set_udp_available(true);
        pair.host_receives(ViewerMedia::request());
        assert_eq!(pair.host.frame_path(), MediaPath::Shared);
        assert!(pair.viewer.set_udp_verified(true, pair.now).unwrap().is_empty());
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(1, key_frame()), "media");
        pair.decode(1);
    }

    #[test]
    fn lost_datagrams_release_old_credit_and_decode_only_the_new_reliable_stream() {
        for (bound, committed) in [(true, false), (true, true), (false, true)] {
            let mut pair = Pair::new();
            pair.offer_udp();
            if bound {
                pair.bind_video();
            }
            pair.verify_udp();
            let ready = pair.host.prepared().unwrap();
            pair.viewer_receives(ready);
            assert_eq!(pair.encode(1, key_frame()), "udp");
            let old = pair.viewer.receiving_stream().unwrap();
            if committed {
                pair.decode(1);
            }
            let late = MediaFrame::new(old, 2, VideoPacket::h264(2, dependent_frame())).unwrap();
            if committed {
                assert_eq!(pair.encode(2, dependent_frame()), "udp");
            }
            let (settled, replies) = pair.host.set_udp_verified(false);
            assert_eq!(settled, 1);
            let events = pair.viewer.set_udp_verified(false, pair.now).unwrap();
            pair.viewer_events(events);
            for reply in replies {
                pair.viewer_receives(reply);
            }
            assert!(pair.viewer.receiving_stream().is_none());
            let path = if bound { MediaPath::Tcp } else { MediaPath::Shared };
            assert_eq!(pair.host.frame_path(), path);
            assert!(pair.viewer.assembled_frame(late, pair.now).unwrap().is_empty());
            let ready = pair.host.prepared().unwrap();
            pair.viewer_receives(ready);
            assert_eq!(pair.encode(2, key_frame()), "media");
            assert!(pair.viewer.decoded(DecodeReceipt::Media(old, 2)).unwrap().is_empty());
            assert_eq!(pair.host.gate(), Gate::Closed);
            pair.decode(2);
            assert_eq!(pair.host.gate(), Gate::Open);
        }
    }

    #[test]
    fn unanswered_opening_keyframes_retry_on_verified_udp_twice_before_reliable_video() {
        let mut pair = Pair::new();
        pair.offer_udp();
        pair.verify_udp();
        for attempt in 1..=3 {
            let ready = pair.host.prepared().unwrap();
            assert_eq!(ready.path.as_deref(), Some("udp"));
            pair.viewer_receives(ready);
            assert!(matches!(pair.host.frame(attempt, key_frame()).unwrap(), HostFrame::Datagram(_)));
            let deadline = pair.viewer.deadline().unwrap();
            pair.now = deadline;
            let events = pair.viewer.tick(deadline).unwrap();
            pair.viewer_events(events);
            assert_eq!(pair.settled, attempt as usize);
            if attempt < 3 {
                assert_eq!(pair.viewer.deadline(), Some(deadline + Duration::from_secs(1)));
                pair.now = pair.viewer.deadline().unwrap();
                let retry = pair.viewer.tick(pair.now).unwrap();
                pair.viewer_events(retry);
            }
        }
        assert_eq!((pair.host.frame_path(), pair.viewer.frame_path()), (MediaPath::Shared, MediaPath::Shared));
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(1, key_frame()), "media");
        pair.decode(1);
        assert_eq!(pair.host.gate(), Gate::Open);
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
        assert_eq!(pair.host.frame_path(), MediaPath::Shared);
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
        assert_eq!(pair.host.frame_path(), MediaPath::Shared);
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
        assert_eq!(pair.host.frame_path(), MediaPath::Tcp);
        let HostFrame::Media(frame) = pair.host.frame(1, key_frame()).unwrap() else { panic!("expected TCP keyframe") };
        assert!(pair.viewer.frame(&frame.payload, pair.now).unwrap().is_empty());
        let accepted = pair.viewer.frame_on(MediaPath::Tcp, &frame.payload, pair.now).unwrap();
        pair.viewer_events(accepted);
        assert_eq!(pair.host.gate(), Gate::Closed);
        pair.decode(1);
        assert_eq!(pair.host.gate(), Gate::Open);
        assert_eq!(pair.host.frame_path(), MediaPath::Tcp);
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
            assert_eq!(pair.host.frame_path(), MediaPath::Shared);
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
    fn a_commit_confirmed_after_capture_changes_recovers_the_viewers_actual_stream() {
        let mut pair = Pair::new();
        pair.open();
        let initial = pair.viewer.active().unwrap();
        pair.viewer_receives(MediaControl::recover(initial));
        let selected = *pair.prepared.last().unwrap();
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(2, key_frame()), "media");

        let decoded = pair.viewer.decoded(DecodeReceipt::Media(selected, 2)).unwrap();
        let [ViewerMediaEvent::Send(_), ViewerMediaEvent::Send(confirm)] = decoded.as_slice() else { panic!("missing decodedReady") };
        let replies = pair.host.control(&MediaControl::read(confirm).unwrap(), false).unwrap();
        let [HostMediaEvent::Settled(1), HostMediaEvent::Send(commit)] = replies.as_slice() else { panic!("missing commit") };
        let events = pair.viewer.control(commit, pair.now).unwrap();
        let [ViewerMediaEvent::Committed(_), ViewerMediaEvent::Send(committed)] = events.as_slice() else { panic!("missing committed") };
        let acknowledged = MediaControl::read(committed).unwrap();
        assert_eq!(pair.viewer.active(), Some(selected));

        // During the platform switch only abort is sent. The prior stream is still the host's last confirmation.
        let (count, controls) = pair.host.interrupted();
        assert_eq!(count, 0);
        assert_eq!(controls[0].operation, MediaOperation::Abort);
        pair.viewer_receives(controls[0].clone());
        assert_eq!(pair.host.gate(), Gate::Closed);
        let previous = pair.host.recovery().unwrap();
        assert_eq!(previous, MediaControl::recover(initial));
        assert!(pair.viewer.control(&previous, pair.now).unwrap().is_empty());
        let mut unrelated = acknowledged.clone();
        unrelated.transaction_id = Some(Uuid::new_v4());
        assert!(pair.host.control(&unrelated, false).unwrap().is_empty());

        // The session reads the delayed confirmation once platform reconfiguration returns.
        pair.host_receives(acknowledged.clone());
        assert!(pair.host.control(&acknowledged, false).unwrap().is_empty());
        let next = *pair.prepared.last().unwrap();
        assert!(next.transport_epoch > selected.transport_epoch);
        assert_eq!(pair.host.gate(), Gate::Closed);
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.encode(3, key_frame()), "media");
        pair.decode(3);
        assert_eq!((pair.viewer.active(), pair.host.gate()), (Some(next), Gate::Open));
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
        let expired = MediaFeedback { missing: Vec::new(), kind: FeedbackKind::Expired, header: MediaFrameHeader { stream: third, frame_id: 1, is_idr: true } };
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
            assert_eq!(pair.host.feedback(&MediaFeedback { missing: Vec::new(), kind: FeedbackKind::Decoded, header: wrong }), (0, Vec::new()));
        }
        assert_eq!(pair.host.deadline(), Some(deadline));
        // Repeated receipt of an already reassembled frame cannot postpone recovery indefinitely.
        pair.host.feedback(&MediaFeedback { missing: Vec::new(), kind: FeedbackKind::Reassembled, header });
        assert_eq!(pair.host.deadline(), Some(deadline));
        assert_eq!(pair.host.expire(deadline - Duration::from_millis(1)), (0, Vec::new()));
        assert_eq!(pair.host.expire(deadline), (1, vec![MediaControl::recover(stream)]));
        assert!(pair.host.deadline().is_none());
        assert_eq!(pair.host.gate(), Gate::Closed);

        let events = pair.viewer.tick(pair.now + FRAME_TIMEOUT).unwrap();
        assert!(matches!(&events[..], [ViewerMediaEvent::Send(feedback), ViewerMediaEvent::Send(prepare)]
            if MediaFeedback::decode(&feedback.payload).unwrap() == MediaFeedback { missing: Vec::new(), kind: FeedbackKind::Expired, header }
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
    fn audio_datagrams_require_the_first_offers_agreement_and_a_live_verified_path() {
        let now = Instant::now();
        let mut request = ViewerMedia::request();
        let mut viewer = ViewerMedia::default();
        viewer.request_datagram_audio(&mut request);
        let mut host = HostMedia::default();
        let initial = host.control(&request, false).unwrap();
        assert!(host.datagram_audio);
        let [HostMediaEvent::Send(offer)] = initial.as_slice() else { panic!("missing offer") };
        let mut capable = offer.clone();
        capable.path = Some("udp".into());
        capable.datagram_audio = Some(true);
        let mut old = ViewerMedia::default();
        for side in [&mut viewer, &mut old] {
            side.set_udp_available(true);
            side.control(&capable, now).unwrap();
            assert!(!side.receives_datagram_audio());
            side.set_udp_verified(true, now).unwrap();
        }
        assert!(viewer.receives_datagram_audio());
        assert!(!old.receives_datagram_audio());
        viewer.set_udp_verified(false, now).unwrap();
        assert!(!viewer.receives_datagram_audio());
        let mut legacy = HostMedia::default();
        legacy.control(&ViewerMedia::request(), false).unwrap();
        legacy.control(&request, false).unwrap();
        assert!(!legacy.datagram_audio);
    }

    #[test]
    fn only_the_first_bilateral_offer_opens_the_24_frame_decode_window() {
        let now = Instant::now();
        let mut host = HostMedia::default();
        let mut viewer = ViewerMedia::default();
        let mut request = ViewerMedia::request();
        viewer.request_dynamic_window(&mut request);
        assert_eq!(viewer.receive_capacity(), window::STATIC_FRAMES);
        let initial = host.control(&request, false).unwrap();
        let [HostMediaEvent::Send(offer)] = initial.as_slice() else {
            panic!("expected an offer");
        };
        assert_eq!(offer.dynamic_frame_window, Some(true));
        viewer.control(offer, now).unwrap();
        let mut older = offer.clone();
        older.dynamic_frame_window = None;
        viewer.control(&older, now).unwrap();
        assert_eq!(viewer.receive_capacity(), window::MAX_DYNAMIC_FRAMES);
        for seq in 0..window::MAX_DYNAMIC_FRAMES as u32 {
            viewer.legacy(seq, 1).unwrap();
        }
        assert!(viewer.legacy(24, 1).is_err());
        viewer.decoded(DecodeReceipt::Legacy(19)).unwrap();
        viewer.legacy(24, 1).unwrap();
        let mut unsolicited = ViewerMedia::default();
        unsolicited.control(offer, now).unwrap();
        assert_eq!(unsolicited.receive_capacity(), window::STATIC_FRAMES);
        let mut legacy = HostMedia::default();
        legacy.control(&ViewerMedia::request(), false).unwrap();
        let events = legacy.control(&request, false).unwrap();
        assert!(matches!(events.as_slice(),[HostMediaEvent::Send(reply)] if reply.dynamic_frame_window.is_none()));
    }

    #[test]
    fn pending_decode_limits_bound_work_across_legacy_and_media_streams() {
        let mut viewer = ViewerMedia::default();
        viewer.legacy(1, window::MAX_BUFFERED_BYTES).unwrap();
        assert!(viewer.legacy(2, 1).is_err());
        viewer.decoded(DecodeReceipt::Legacy(1)).unwrap();
        for sequence in 0..window::STATIC_FRAMES as u32 {
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
        for _ in 0..=window::STATIC_FRAMES {
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

    fn fast_pair(path: MediaPath) -> Pair {
        let mut pair = Pair::new();
        let mut request = ViewerMedia::request();
        pair.viewer.request_fast_recovery(&mut request);
        if path == MediaPath::Udp {
            pair.viewer.set_udp_available(true);
            pair.host.set_udp_available(true);
        }
        pair.host_receives(request);
        if path == MediaPath::Udp {
            pair.verify_udp();
        }
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        assert_eq!(pair.key_frames_wanted, 1);
        pair.encode(30, key_frame());
        pair.decode(30);
        assert_eq!(pair.committed.len(), 1);
        pair
    }

    #[test]
    fn fast_udp_opens_once_after_its_own_probe_and_holds_early_video_until_ready() {
        let mut pair = fast_pair(MediaPath::Udp);
        let old = pair.committed[0];
        let events = pair.viewer.control(&MediaControl::recover(old), pair.now).unwrap();
        let [ViewerMediaEvent::Send(tls), ViewerMediaEvent::DatagramPrepare(copy)] = &events[..] else { panic!("expected both copies") };
        assert_eq!(copy[0], 11);
        assert_eq!(&copy[1..], tls.payload);
        let prepare = MediaControl::read(tls).unwrap();
        assert_eq!(prepare.fast, Some(true));
        let id = prepare.transaction_id.unwrap();
        let stream = pair.viewer.receiving_stream().unwrap();
        pair.host_receives(prepare.clone());
        assert!(pair.host.control(&prepare, false).unwrap().is_empty());
        let ready = pair.host.prepared().unwrap();
        assert_eq!(pair.host.pending_fast_challenge(), Some(id));
        pair.host.answered_fast_challenge(Uuid::new_v4());
        assert!(!pair.host.take_fast_keyframe());
        assert_eq!(pair.host.gate(), Gate::Closed);
        let repeated = pair.host.control(&prepare, false).unwrap();
        assert!(matches!(&repeated[..], [HostMediaEvent::Send(replay)] if **replay == ready));
        assert!(!pair.host.take_fast_keyframe());
        pair.host.answered_fast_challenge(id);
        assert!(pair.host.take_fast_keyframe());
        assert!(!pair.host.take_fast_keyframe());
        assert_eq!(pair.encode(31, key_frame()), "udp");
        assert_eq!(pair.video.len(), 1, "Ready is still in flight");
        assert!(pair.viewer.decoded(DecodeReceipt::Media(stream, 31)).unwrap().is_empty());
        pair.viewer_receives(ready.clone());
        pair.viewer_receives(ready);
        assert_eq!(pair.video.len(), 2);
        assert_eq!(pair.settled, 1);
        let events = pair.viewer.decoded(DecodeReceipt::Media(stream, 31)).unwrap();
        let [ViewerMediaEvent::DatagramFeedback(feedback), ViewerMediaEvent::Committed(local), ViewerMediaEvent::Send(committed)] = &events[..] else {
            panic!("expected actual decoded receipt and direct committed")
        };
        assert_eq!(*local, stream);
        assert_eq!(feedback.kind, FeedbackKind::Decoded);
        // The TLS confirmation may precede its UDP receipt.
        pair.host_receives(MediaControl::read(committed).unwrap());
        assert_eq!(pair.host.gate(), Gate::Open);
        assert_eq!(pair.host.feedback(feedback), (0, Vec::new()));
        assert_eq!(pair.settled, 2);
    }

    #[test]
    fn datagram_prepare_retries_are_bounded_and_an_aborted_nonce_cannot_restart_the_encoder() {
        let mut pair = fast_pair(MediaPath::Udp);
        let events = pair.viewer.control(&MediaControl::recover(pair.committed[0]), pair.now).unwrap();
        let [ViewerMediaEvent::Send(tls), ViewerMediaEvent::DatagramPrepare(first)] = &events[..] else { panic!("expected fast recovery") };
        let prepare = MediaControl::read(tls).unwrap();
        pair.host_receives(prepare.clone());
        let stream = *pair.prepared.last().unwrap();
        let _ = pair.host.prepared().unwrap();
        for _ in 1..MAX_FAST_REQUESTS {
            pair.now += FAST_REQUEST_INTERVAL;
            assert!(matches!(&pair.viewer.tick(pair.now).unwrap()[..], [ViewerMediaEvent::DatagramPrepare(copy)] if copy == first));
        }
        assert!(pair.viewer.tick(pair.now + FAST_REQUEST_INTERVAL).unwrap().is_empty());
        let abort = MediaControl::transaction(MediaOperation::Abort, prepare.transaction_id.unwrap(), stream, "udp");
        pair.host_receives(abort);
        pair.host.answered_fast_challenge(prepare.transaction_id.unwrap());
        assert!(!pair.host.take_fast_keyframe());
        assert_eq!(pair.host.pending_fast_challenge(), None);
        assert_ne!(pair.host.gate(), Gate::One);
    }

    #[test]
    fn reliable_fast_recovery_finishes_on_decoded_feedback_and_path_changes_keep_the_full_handshake() {
        let mut pair = fast_pair(MediaPath::Shared);
        pair.viewer.set_udp_available(true);
        pair.host.set_udp_available(true);
        let events = pair.viewer.control(&MediaControl::recover(pair.committed[0]), pair.now).unwrap();
        let [ViewerMediaEvent::Send(prepare)] = &events[..] else { panic!("reliable recovery has no UDP copies") };
        let prepare = MediaControl::read(prepare).unwrap();
        assert_eq!(prepare.fast, Some(true));
        pair.host_receives(prepare);
        let ready = pair.host.prepared().unwrap();
        assert_eq!(pair.host.pending_fast_challenge(), None);
        assert!(pair.host.take_fast_keyframe());
        pair.viewer_receives(ready);
        pair.encode(32, key_frame());
        pair.decode(32);
        assert_eq!(pair.committed.len(), 2);
        assert_eq!(pair.host.gate(), Gate::Open);
        assert_eq!(pair.settled, 2);
        let events = pair.viewer.set_udp_verified(true, pair.now).unwrap();
        let [ViewerMediaEvent::Send(prepare)] = &events[..] else { panic!("expected reliable Prepare only") };
        let prepare = MediaControl::read(prepare).unwrap();
        assert_eq!(prepare.path.as_deref(), Some("udp"));
        assert_eq!(prepare.fast, None);
        assert_eq!(pair.viewer.receiving_stream(), None);
    }

    #[test]
    fn an_unsolicited_fast_offer_and_a_repeated_request_cannot_enable_fast_recovery() {
        let mut pair = Pair::new();
        let request = ViewerMedia::request();
        let [HostMediaEvent::Send(offer)] = &pair.host.control(&request, false).unwrap()[..] else { panic!("expected offer") };
        assert_eq!(offer.fast_recovery, None);
        let mut repeated = request;
        repeated.fast_recovery = Some(true);
        let [HostMediaEvent::Send(same)] = &pair.host.control(&repeated, false).unwrap()[..] else { panic!("expected same offer") };
        assert_eq!(offer, same);
        let mut unsolicited = (**offer).clone();
        unsolicited.fast_recovery = Some(true);
        pair.viewer_receives(unsolicited);
        let ready = pair.host.prepared().unwrap();
        pair.viewer_receives(ready);
        pair.encode(40, key_frame());
        pair.decode(40);
        let events = pair.viewer.control(&MediaControl::recover(pair.committed[0]), pair.now).unwrap();
        let [ViewerMediaEvent::Send(prepare)] = &events[..] else { panic!("expected full transaction") };
        assert_eq!(MediaControl::read(prepare).unwrap().fast, None);
        assert_eq!(pair.viewer.receiving_stream(), None);
    }
}
