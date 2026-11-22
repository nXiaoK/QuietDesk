//! XOR and systematic Cauchy Reed–Solomon records used by the macOS media protocol.
mod galois;
use super::*;
use std::collections::BTreeMap;

pub const MAX_PROTECTED_FRAGMENTS: usize = 4096;
pub const LEGACY_PROTECTED_FRAGMENTS: usize = 256;
pub const MAX_XOR_FRAGMENTS: usize = 8;
const SEND_BLOCK: usize = 10;
const MAX_BLOCK: usize = 16;
const MAX_PARITY: usize = 4;
pub const XOR_KIND: u8 = 8;
pub const BLOCK_KIND: u8 = 10;

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum Protection {
    Xor,
    Block { parity_per_block: u8 },
}

impl Protection {
    /// Application datagram length including its outer kind.
    pub fn wire_len(self) -> usize {
        let fields = match self {
            Self::Xor => 6,
            Self::Block { .. } => 12,
        };
        1 + crate::media::HEADER_BYTES + fields + PAYLOAD
    }
}

#[derive(Clone, Copy)]
struct Layout {
    start: usize,
    count: usize,
    parity: usize,
}

fn partition(count: usize, parity: u8) -> impl Iterator<Item = Layout> {
    let blocks = if (2..=MAX_PROTECTED_FRAGMENTS).contains(&count) && (1..=3).contains(&parity) { count.div_ceil(SEND_BLOCK) } else { 0 };
    (0..blocks).map(move |i| {
        let base = count / blocks;
        let remainder = count % blocks;
        let size = base + usize::from(i < remainder);
        Layout { start: i * base + i.min(remainder), count: size, parity: usize::from(parity).min(size - 1) }
    })
}

pub fn parity_shard_count(fragment_count: usize, protection: Protection) -> usize {
    match protection {
        Protection::Xor => usize::from((2..=MAX_XOR_FRAGMENTS).contains(&fragment_count)),
        Protection::Block { parity_per_block } => partition(fragment_count, parity_per_block).map(|block| block.parity).sum(),
    }
}

pub struct ParityShard {
    after: u16,
    datagram: Vec<u8>,
}

impl ParityShard {
    pub fn after_index(&self) -> u16 {
        self.after
    }
    pub fn datagram(self) -> Vec<u8> {
        self.datagram
    }
}

fn xor(into: &mut [u8], data: &[u8]) {
    for (target, source) in into.iter_mut().zip(data) {
        *target ^= *source;
    }
}

pub struct ParityBlock {
    frame: Arc<[u8]>,
    header: MediaFrameHeader,
    layout: Layout,
    protection: Protection,
}

impl ParityBlock {
    pub fn after_index(&self) -> u16 {
        (self.layout.start + self.layout.count - 1) as u16
    }

    pub fn shard_count(&self) -> usize {
        self.layout.parity
    }

    /// Called as the sender reaches the block's last original fragment.
    pub fn encode(self) -> Vec<ParityShard> {
        let frame_count = self.frame.len().div_ceil(PAYLOAD);
        let block = self.layout;
        let start = block.start * PAYLOAD;
        let end = ((block.start + block.count) * PAYLOAD).min(self.frame.len());
        let pieces = self.frame[start..end].chunks(PAYLOAD);
        let (outer, inner) = match self.protection {
            Protection::Xor => (XOR_KIND, 4),
            Protection::Block { .. } => (BLOCK_KIND, 5),
        };
        (0..block.parity)
            .map(|row| {
                let mut wire = Vec::with_capacity(self.protection.wire_len());
                wire.push(outer);
                wire.extend_from_slice(&begin(inner, &self.header, 0));
                wire.extend_from_slice(&(self.frame.len() as u32).to_be_bytes());
                wire.extend_from_slice(&(frame_count as u16).to_be_bytes());
                match self.protection {
                    Protection::Xor => {
                        let offset = wire.len();
                        wire.resize(offset + PAYLOAD, 0);
                        for p in pieces.clone() {
                            xor(&mut wire[offset..], p);
                        }
                    }
                    Protection::Block { .. } => {
                        wire.extend_from_slice(&(block.start as u16).to_be_bytes());
                        wire.extend_from_slice(&[block.count as u8, row as u8, block.parity as u8, 0]);
                        wire.extend_from_slice(&galois::encode(pieces.clone(), row));
                    }
                }
                ParityShard { after: self.after_index(), datagram: wire }
            })
            .collect()
    }
}

pub fn plan(originals: &[OutgoingFragment], protection: Protection) -> Result<Vec<ParityBlock>> {
    let count = originals.len();
    if parity_shard_count(count, protection) == 0 {
        return Ok(Vec::new());
    }
    let first = &originals[0];
    if count != first.frame.len().div_ceil(PAYLOAD)
        || originals.iter().enumerate().any(|(i, p)| usize::from(p.index) != i || p.header != first.header || !Arc::ptr_eq(&p.frame, &first.frame))
    {
        return Err(DeskError::invalid("纠错分片所属帧或顺序无效"));
    }
    let make = |layout| ParityBlock { frame: first.frame.clone(), header: first.header, layout, protection };
    Ok(match protection {
        Protection::Xor => vec![make(Layout { start: 0, count, parity: 1 })],
        Protection::Block { parity_per_block } => partition(count, parity_per_block).map(make).collect(),
    })
}

pub(super) struct Record<'a> {
    pub header: MediaFrameHeader,
    pub bytes: usize,
    pub count: usize,
    block: Option<(Layout, usize)>,
    payload: &'a [u8],
}

impl<'a> Record<'a> {
    pub fn read(kind: u8, data: &'a [u8]) -> Result<Self> {
        let (inner, limit) = match kind {
            XOR_KIND => (4, MAX_XOR_FRAGMENTS),
            BLOCK_KIND => (5, MAX_PROTECTED_FRAGMENTS),
            _ => return Err(DeskError::invalid("纠错数据报类型无效")),
        };
        let mut reader = ByteReader::new(data);
        let header = read_header(&mut reader, inner)?;
        let bytes = reader.u32()? as usize;
        let count = usize::from(reader.u16()?);
        if !(2..=limit).contains(&count) || count != bytes.div_ceil(PAYLOAD) {
            return Err(DeskError::invalid("纠错帧尺寸或片数不符"));
        }
        let block = if kind == BLOCK_KIND {
            let start = usize::from(reader.u16()?);
            let size = usize::from(reader.u8()?);
            let row = usize::from(reader.u8()?);
            let parity = usize::from(reader.u8()?);
            if reader.u8()? != 0 || !(2..=MAX_BLOCK).contains(&size) || !(1..=MAX_PARITY).contains(&parity) || row >= parity || start + size > count {
                return Err(DeskError::invalid("分块纠错字段无效"));
            }
            Some((Layout { start, count: size, parity }, row))
        } else {
            None
        };
        if reader.remaining() != PAYLOAD {
            return Err(DeskError::invalid("纠错校验片长度无效"));
        }
        Ok(Self { header, bytes, count, block, payload: reader.bytes(PAYLOAD)? })
    }

    pub fn exposed_end(&self) -> usize {
        self.block.map_or(self.count, |(block, _)| block.start + block.count)
    }
}

struct StoredBlock {
    layout: Layout,
    rows: [Option<Box<[u8]>>; MAX_PARITY],
}

#[derive(Default)]
pub(super) struct Stored {
    xor: Option<Box<[u8]>>,
    blocks: BTreeMap<usize, StoredBlock>,
    pub bytes: usize,
}

impl Stored {
    pub fn add(&mut self, record: &Record<'_>, available: usize) -> Result<bool> {
        let slot = if let Some((layout, row)) = record.block {
            if !self.blocks.contains_key(&layout.start) {
                let end = layout.start + layout.count;
                if self.blocks.range(..end).next_back().is_some_and(|(_, b)| b.layout.start + b.layout.count > layout.start) {
                    return Err(DeskError::invalid("同一帧的纠错块范围重叠"));
                }
            }
            let stored = self.blocks.entry(layout.start).or_insert_with(|| StoredBlock { layout, rows: Default::default() });
            if stored.layout.count != layout.count || stored.layout.parity != layout.parity {
                return Err(DeskError::invalid("同一媒体帧的纠错块参数冲突"));
            }
            &mut stored.rows[row]
        } else {
            &mut self.xor
        };
        if let Some(previous) = slot {
            return if &**previous == record.payload { Ok(false) } else { Err(DeskError::invalid("重复纠错内容冲突")) };
        }
        if available < PAYLOAD {
            return Err(DeskError::invalid("纠错缓存已满"));
        }
        *slot = Some(record.payload.into());
        self.bytes += PAYLOAD;
        Ok(true)
    }

    pub fn recover(&self, index: usize, data: &[u8], received: &[bool]) -> Result<Vec<(usize, Vec<u8>)>> {
        let payload = |i: usize| &data[i * PAYLOAD..((i + 1) * PAYLOAD).min(data.len())];
        if let Some(parity) = &self.xor {
            let mut missing = received.iter().enumerate().filter(|(_, present)| !**present);
            if let Some((i, _)) = missing.next()
                && missing.next().is_none()
            {
                let mut recovered = parity.to_vec();
                for (j, present) in received.iter().enumerate() {
                    if *present {
                        xor(&mut recovered, payload(j));
                    }
                }
                return Ok(vec![(i, recovered)]);
            }
        }
        let Some((_, block)) = self.blocks.range(..=index).next_back() else {
            return Ok(Vec::new());
        };
        let layout = block.layout;
        if index >= layout.start + layout.count {
            return Ok(Vec::new());
        }
        let shards: Vec<_> = (layout.start..layout.start + layout.count).map(|i| received[i].then(|| payload(i))).collect();
        let mut rebuilt = galois::recover(&shards, &block.rows)?;
        for (i, _) in &mut rebuilt {
            *i += layout.start;
        }
        Ok(rebuilt)
    }
}
