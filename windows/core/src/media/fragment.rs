//! Fragment records inside authenticated video datagrams. The outer DTLS kind is set by the session.
mod receive;
mod repair;
pub use receive::{ReceiveEvent, Receiver};
pub use repair::{RepairCache, SendEvent};

use super::{FragmentRange, MediaFeedback, MediaFrame, MediaFrameHeader, MediaStreamId, begin, read_header};
use crate::error::{DeskError, Result};
use crate::wire::ByteReader;
use std::sync::Arc;
use std::time::Duration;

pub const MAX_RECORD_BYTES: usize = 1100;
const RECORD_KIND: u8 = 2;
const FRAGMENT_HEADER: usize = super::HEADER_BYTES + 16;
const PAYLOAD: usize = MAX_RECORD_BYTES - FRAGMENT_HEADER;
const FRAME_WINDOW: usize = 6;
const BYTE_BUDGET: usize = 32 * 1024 * 1024;
const REORDER_DELAY: Duration = Duration::from_millis(3);
const NACK_INTERVAL: Duration = Duration::from_millis(10);
const DECODE_TIMEOUT: Duration = Duration::from_secs(5);

struct Incoming<'a> {
    header: MediaFrameHeader,
    bytes: usize,
    index: usize,
    count: usize,
    payload: &'a [u8],
}

impl<'a> Incoming<'a> {
    fn read(record: &'a [u8]) -> Result<Self> {
        if record.len() > MAX_RECORD_BYTES {
            return Err(DeskError::invalid("媒体数据报过大"));
        }
        let mut reader = ByteReader::new(record);
        let header = read_header(&mut reader, RECORD_KIND)?;
        let _packet_sequence = reader.u64()?;
        let bytes = reader.u32()? as usize;
        let index = usize::from(reader.u16()?);
        let count = usize::from(reader.u16()?);
        if !(1..=MediaFrame::MAXIMUM_PACKET_BYTES).contains(&bytes) || count != bytes.div_ceil(PAYLOAD) || index >= count {
            return Err(DeskError::invalid("媒体分片编号或总长度无效"));
        }
        let payload = reader.bytes(reader.remaining())?;
        if payload.len() != PAYLOAD.min(bytes - index * PAYLOAD) {
            return Err(DeskError::invalid("媒体分片长度无效"));
        }
        Ok(Self { header, bytes, index, count, payload })
    }
}

/// Repairs reuse the original packet sequence and payload.
#[derive(Debug, Clone)]
pub struct OutgoingFragment {
    header: MediaFrameHeader,
    index: u16,
    sequence: u64,
    frame: Arc<[u8]>,
}

impl OutgoingFragment {
    pub fn header(&self) -> MediaFrameHeader {
        self.header
    }
    pub fn index(&self) -> u16 {
        self.index
    }
    pub fn record(&self) -> Vec<u8> {
        let start = usize::from(self.index) * PAYLOAD;
        let payload = &self.frame[start..(start + PAYLOAD).min(self.frame.len())];
        let mut data = begin(RECORD_KIND, &self.header, 16 + payload.len());
        data.extend_from_slice(&self.sequence.to_be_bytes());
        data.extend_from_slice(&(self.frame.len() as u32).to_be_bytes());
        data.extend_from_slice(&self.index.to_be_bytes());
        data.extend_from_slice(&(self.frame.len().div_ceil(PAYLOAD) as u16).to_be_bytes());
        data.extend_from_slice(payload);
        data
    }
}

#[cfg(test)]
mod tests;
