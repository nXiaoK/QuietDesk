//! Independent cursor messages and presentation on a committed video stream.

use crate::error::{DeskError, Result};
use crate::media::MediaStreamId;
use crate::wire::{ByteReader, Message, MessageKind};
use serde::{Deserialize, Serialize};
use std::{io::Cursor, sync::Arc};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CursorOperation {
    Request,
    Status,
    Binding,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CursorReason {
    Unavailable,
    WaitingForResume,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CursorControl {
    pub operation: CursorOperation,
    #[serde(rename = "requestID", skip_serializing_if = "Option::is_none")]
    pub request_id: Option<Uuid>,
    #[serde(rename = "cursorID", skip_serializing_if = "Option::is_none")]
    pub cursor_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub epoch: Option<u32>,
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stream: Option<MediaStreamId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<CursorReason>,
}

impl CursorControl {
    pub fn request(request_id: Uuid, enabled: bool) -> Self {
        Self { operation: CursorOperation::Request, request_id: Some(request_id), cursor_id: None, epoch: None, enabled, stream: None, reason: None }
    }

    pub fn status(request_id: Uuid, cursor_id: Uuid, epoch: u32, enabled: bool, reason: Option<CursorReason>) -> Self {
        Self { operation: CursorOperation::Status, request_id: Some(request_id), cursor_id: Some(cursor_id), epoch: Some(epoch), enabled, stream: None, reason }
    }

    pub fn binding(cursor_id: Uuid, epoch: u32, enabled: bool, stream: MediaStreamId) -> Self {
        Self {
            operation: CursorOperation::Binding,
            request_id: None,
            cursor_id: Some(cursor_id),
            epoch: Some(epoch),
            enabled,
            stream: Some(stream),
            reason: None,
        }
    }

    fn validate(&self) -> Result<()> {
        let valid = match self.operation {
            CursorOperation::Request => {
                self.request_id.is_some() && self.cursor_id.is_none() && self.epoch.is_none() && self.stream.is_none() && self.reason.is_none()
            }
            CursorOperation::Status => {
                self.request_id.is_some() && self.cursor_id.is_some() && self.epoch.is_some_and(|epoch| epoch > 0) && self.stream.is_none()
            }
            CursorOperation::Binding => {
                self.request_id.is_none()
                    && self.cursor_id.is_some()
                    && self.epoch.is_some_and(|epoch| epoch > 0)
                    && self.stream.is_some_and(|stream| stream.transport_epoch > 0 && stream.codec_epoch > 0)
                    && self.reason.is_none()
            }
        };
        if valid { Ok(()) } else { Err(DeskError::invalid("光标控制字段无效")) }
    }

    pub fn message(&self) -> Result<Message> {
        self.validate()?;
        Message::json(MessageKind::CursorControl, self)
    }

    pub fn read(message: &Message) -> Result<Self> {
        let control: Self = message.read_json()?;
        control.validate()?;
        Ok(control)
    }
}

const MAX_PNG_BYTES: usize = 256 * 1024;
const MAX_SIDE: u16 = 256;

#[derive(Clone, Debug, PartialEq)]
pub struct CursorImage {
    pub png: Vec<u8>,
    pub pixel_width: u16,
    pub pixel_height: u16,
    pub logical_width: f64,
    pub logical_height: f64,
    pub hot_spot_x: f64,
    pub hot_spot_y: f64,
}

impl CursorImage {
    fn validate_geometry(&self) -> Result<()> {
        if !(1..=MAX_SIDE).contains(&self.pixel_width)
            || !(1..=MAX_SIDE).contains(&self.pixel_height)
            || !(0.5..=256.0).contains(&self.logical_width)
            || !(0.5..=256.0).contains(&self.logical_height)
            || !(0.0..=self.logical_width).contains(&self.hot_spot_x)
            || !(0.0..=self.logical_height).contains(&self.hot_spot_y)
        {
            return Err(DeskError::invalid("光标图片参数无效"));
        }
        Ok(())
    }

    fn validate_png(&self) -> Result<()> {
        if !(33..=MAX_PNG_BYTES).contains(&self.png.len())
            || !self.png.starts_with(b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR")
            || self.png[16..20] != u32::from(self.pixel_width).to_be_bytes()
            || self.png[20..24] != u32::from(self.pixel_height).to_be_bytes()
        {
            return Err(DeskError::invalid("光标 PNG 尺寸或格式无效"));
        }
        Ok(())
    }

    pub fn from_rgba(
        pixel_width: u16,
        pixel_height: u16,
        logical_width: f64,
        logical_height: f64,
        hot_spot_x: f64,
        hot_spot_y: f64,
        rgba: &[u8],
    ) -> Result<Self> {
        let mut image = Self { png: Vec::new(), pixel_width, pixel_height, logical_width, logical_height, hot_spot_x, hot_spot_y };
        image.validate_geometry()?;
        if rgba.len() != usize::from(pixel_width) * usize::from(pixel_height) * 4 {
            return Err(DeskError::invalid("光标像素长度无效"));
        }
        let mut encoder = png::Encoder::new(&mut image.png, u32::from(pixel_width), u32::from(pixel_height));
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().map_err(png_error)?;
        writer.write_image_data(rgba).map_err(png_error)?;
        writer.finish().map_err(png_error)?;
        if image.png.len() > MAX_PNG_BYTES {
            return Err(DeskError::invalid("光标 PNG 过大"));
        }
        Ok(image)
    }

    pub fn rgba(&self) -> Result<Vec<u8>> {
        let mut decoder = png::Decoder::new_with_limits(Cursor::new(&self.png), png::Limits { bytes: 2 * 1024 * 1024 });
        decoder.set_ignore_text_chunk(true);
        decoder.set_ignore_iccp_chunk(true);
        decoder.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
        let mut reader = decoder.read_info().map_err(png_error)?;
        // Cursor PNGs carry a single complete bitmap. An APNG sub-frame can have its own size.
        let size = reader.output_buffer_size().filter(|size| *size <= usize::from(MAX_SIDE).pow(2) * 4).ok_or_else(|| DeskError::invalid("光标像素过大"))?;
        let mut pixels = vec![0; size];
        let info = reader.next_frame(&mut pixels).map_err(png_error)?;
        if (info.width, info.height) != (u32::from(self.pixel_width), u32::from(self.pixel_height)) {
            return Err(DeskError::invalid("光标 PNG 尺寸不一致"));
        }
        pixels.truncate(info.buffer_size());
        match info.color_type {
            png::ColorType::Rgba => Ok(pixels),
            png::ColorType::GrayscaleAlpha => Ok(pixels.as_chunks::<2>().0.iter().flat_map(|&[gray, alpha]| [gray, gray, gray, alpha]).collect()),
            _ => Err(DeskError::invalid("无法转换光标 PNG 颜色")),
        }
    }
}

fn png_error(error: impl std::fmt::Display) -> DeskError {
    DeskError::invalid(format!("处理光标 PNG 失败：{error}"))
}

#[derive(Clone, Debug, PartialEq)]
pub struct CursorShape {
    pub cursor_id: Uuid,
    pub epoch: u32,
    pub revision: u64,
    pub image: Option<Arc<CursorImage>>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CursorPosition {
    pub cursor_id: Uuid,
    pub epoch: u32,
    pub sequence: u64,
    pub inside_display: bool,
    pub x: f64,
    pub y: f64,
}

fn check_serial(epoch: u32, sequence: u64) -> Result<()> {
    if epoch == 0 || sequence == 0 { Err(DeskError::invalid("光标代次或序号无效")) } else { Ok(()) }
}

fn header(kind: u8, cursor_id: Uuid, epoch: u32, sequence: u64) -> Result<Vec<u8>> {
    check_serial(epoch, sequence)?;
    let mut data = vec![0x43, 0x55, 1, kind];
    data.extend_from_slice(cursor_id.as_bytes());
    data.extend_from_slice(&epoch.to_be_bytes());
    data.extend_from_slice(&sequence.to_be_bytes());
    Ok(data)
}

fn read_header(reader: &mut ByteReader, kind: u8) -> Result<(Uuid, u32, u64)> {
    if reader.bytes(4)? != [0x43, 0x55, 1, kind] {
        return Err(DeskError::invalid("光标协议头无效"));
    }
    let cursor_id = Uuid::from_bytes(reader.bytes(16)?.try_into().unwrap());
    let epoch = reader.u32()?;
    let sequence = reader.u64()?;
    check_serial(epoch, sequence)?;
    Ok((cursor_id, epoch, sequence))
}

fn read_flag(reader: &mut ByteReader) -> Result<bool> {
    match reader.u8()? {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(DeskError::invalid("光标标记无效")),
    }
}

impl CursorShape {
    pub fn message(&self) -> Result<Message> {
        let mut data = header(1, self.cursor_id, self.epoch, self.revision)?;
        data.push(u8::from(self.image.is_some()));
        if let Some(image) = &self.image {
            image.validate_geometry()?;
            image.validate_png()?;
            data.extend_from_slice(&image.pixel_width.to_be_bytes());
            data.extend_from_slice(&image.pixel_height.to_be_bytes());
            for value in [image.logical_width, image.logical_height, image.hot_spot_x, image.hot_spot_y] {
                data.extend_from_slice(&value.to_be_bytes());
            }
            data.extend_from_slice(&(image.png.len() as u32).to_be_bytes());
            data.extend_from_slice(&image.png);
        }
        Ok(Message::new(MessageKind::CursorShape, data))
    }

    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.len() > MAX_PNG_BYTES + 80 {
            return Err(DeskError::invalid("光标形状消息过大"));
        }
        let mut reader = ByteReader::new(data);
        let (cursor_id, epoch, revision) = read_header(&mut reader, 1)?;
        let image = if read_flag(&mut reader)? {
            let pixel_width = reader.u16()?;
            let pixel_height = reader.u16()?;
            let logical_width = f64::from_bits(reader.u64()?);
            let logical_height = f64::from_bits(reader.u64()?);
            let hot_spot_x = f64::from_bits(reader.u64()?);
            let hot_spot_y = f64::from_bits(reader.u64()?);
            let length = reader.u32()? as usize;
            if length != reader.remaining() {
                return Err(DeskError::invalid("光标图片长度无效"));
            }
            let image = CursorImage { png: reader.bytes(length)?.to_vec(), pixel_width, pixel_height, logical_width, logical_height, hot_spot_x, hot_spot_y };
            image.validate_geometry()?;
            image.validate_png()?;
            Some(Arc::new(image))
        } else {
            if reader.remaining() != 0 {
                return Err(DeskError::invalid("光标形状有多余数据"));
            }
            None
        };
        Ok(Self { cursor_id, epoch, revision, image })
    }
}

impl CursorPosition {
    fn validate_xy(&self) -> Result<()> {
        if (0.0..=1.0).contains(&self.x) && (0.0..=1.0).contains(&self.y) { Ok(()) } else { Err(DeskError::invalid("光标位置无效")) }
    }

    pub fn message(&self) -> Result<Message> {
        self.validate_xy()?;
        let mut data = header(2, self.cursor_id, self.epoch, self.sequence)?;
        data.push(u8::from(self.inside_display));
        data.extend_from_slice(&self.x.to_be_bytes());
        data.extend_from_slice(&self.y.to_be_bytes());
        Ok(Message::new(MessageKind::CursorPosition, data))
    }

    pub fn decode(data: &[u8]) -> Result<Self> {
        if data.len() != 49 {
            return Err(DeskError::invalid("光标位置长度无效"));
        }
        let mut reader = ByteReader::new(data);
        let (cursor_id, epoch, sequence) = read_header(&mut reader, 2)?;
        let value =
            Self { cursor_id, epoch, sequence, inside_display: read_flag(&mut reader)?, x: f64::from_bits(reader.u64()?), y: f64::from_bits(reader.u64()?) };
        value.validate_xy()?;
        Ok(value)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Binding {
    cursor_id: Uuid,
    epoch: u32,
    stream: MediaStreamId,
    enabled: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CursorPresentationState {
    pub cursor_id: Option<Uuid>,
    pub epoch: u32,
    pub enabled: bool,
    pub image: Option<Arc<CursorImage>>,
    pub position: Option<CursorPosition>,
    revision: u64,
    committed_stream: Option<MediaStreamId>,
    bindings: Vec<Binding>,
    pending: Vec<Binding>,
}

impl CursorPresentationState {
    pub fn committed_stream(&self) -> Option<MediaStreamId> {
        self.committed_stream
    }

    pub fn status(&mut self, status: &CursorControl) -> bool {
        let (CursorOperation::Status, Some(id), Some(epoch)) = (status.operation, status.cursor_id, status.epoch) else { return false };
        if self.cursor_id.is_some_and(|current| current != id) || epoch <= self.epoch {
            return false;
        }
        self.cursor_id = Some(id);
        self.epoch = epoch;
        self.revision = 0;
        self.image = None;
        self.position = None;
        for binding in std::mem::take(&mut self.pending).into_iter().filter(|binding| binding.cursor_id == id) {
            if binding.epoch == epoch && self.committed_stream.is_none_or(|stream| newer(binding.stream, stream)) {
                retain_binding(&mut self.bindings, binding);
            } else if binding.epoch > epoch {
                self.pending.push(binding);
            }
        }
        true
    }

    pub fn bind(&mut self, control: &CursorControl) -> bool {
        let (CursorOperation::Binding, Some(cursor_id), Some(epoch), Some(stream)) = (control.operation, control.cursor_id, control.epoch, control.stream)
        else {
            return false;
        };
        if self.cursor_id.is_some_and(|id| id != cursor_id) || self.committed_stream.is_some_and(|current| !newer(stream, current)) || epoch < self.epoch {
            return false;
        }
        let binding = Binding { cursor_id, epoch, stream, enabled: control.enabled };
        if self.cursor_id == Some(cursor_id) && epoch == self.epoch {
            retain_binding(&mut self.bindings, binding);
        } else if epoch > self.epoch {
            retain_binding(&mut self.pending, binding);
        } else {
            return false;
        }
        true
    }

    pub fn commit(&mut self, stream: MediaStreamId) -> bool {
        let Some(binding) = self.bindings.iter().find(|binding| binding.stream == stream && binding.epoch == self.epoch) else { return false };
        self.committed_stream = Some(stream);
        self.enabled = binding.enabled;
        self.bindings.retain(|binding| newer(binding.stream, stream));
        self.pending.retain(|binding| newer(binding.stream, stream));
        true
    }

    pub fn update_shape(&mut self, shape: &CursorShape) -> bool {
        if self.cursor_id != Some(shape.cursor_id) || self.epoch != shape.epoch || shape.revision <= self.revision {
            return false;
        }
        self.revision = shape.revision;
        self.image.clone_from(&shape.image);
        true
    }

    pub fn update_position(&mut self, position: &CursorPosition) -> bool {
        if self.cursor_id != Some(position.cursor_id) || self.epoch != position.epoch || self.position.is_some_and(|last| position.sequence <= last.sequence) {
            return false;
        }
        self.position = Some(*position);
        true
    }
}

fn newer(candidate: MediaStreamId, current: MediaStreamId) -> bool {
    candidate.session_id == current.session_id && (candidate.transport_epoch, candidate.codec_epoch) > (current.transport_epoch, current.codec_epoch)
}

fn retain_binding(bindings: &mut Vec<Binding>, new: Binding) {
    bindings.retain(|binding| binding.stream != new.stream);
    if bindings.len() >= 3 {
        bindings.clear();
    }
    bindings.push(new);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(transport_epoch: u32, codec_epoch: u32) -> MediaStreamId {
        MediaStreamId { session_id: Uuid::from_bytes([4; 16]), transport_epoch, codec_epoch }
    }

    #[test]
    fn controls_read_swift_fields_and_keep_unknown_extensions_optional() {
        let request = CursorControl::request(Uuid::nil(), true);
        let mut json: serde_json::Value = request.message().unwrap().read_json().unwrap();
        assert_eq!(json, serde_json::json!({"operation":"request", "requestID":Uuid::nil(), "enabled":true}));
        json["futureCapability"] = true.into();
        let read = |value: &serde_json::Value| CursorControl::read(&Message::json(MessageKind::CursorControl, value).unwrap());
        assert_eq!(read(&json).unwrap(), request);
        json["reason"] = "unavailable".into();
        assert!(read(&json).is_err());

        let binding = CursorControl::binding(Uuid::nil(), 2, false, stream(2, 3));
        let json: serde_json::Value = binding.message().unwrap().read_json().unwrap();
        assert_eq!(json["stream"], serde_json::json!({"sessionID":stream(2,3).session_id,"transportEpoch":2,"codecEpoch":3}));
        assert_eq!(read(&json).unwrap(), binding);
    }

    #[test]
    fn position_uses_the_swift_layout_and_normalized_coordinates() {
        let position = CursorPosition { cursor_id: Uuid::from_bytes([3; 16]), epoch: 0x102, sequence: 0x304, inside_display: true, x: 0.25, y: 1.0 };
        let mut data = vec![0x43, 0x55, 1, 2];
        data.extend([3; 16]);
        data.extend([0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 3, 4, 1, 0x3f, 0xd0, 0, 0, 0, 0, 0, 0, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(position.message().unwrap(), Message::new(MessageKind::CursorPosition, data.clone()));
        assert_eq!(CursorPosition::decode(&data).unwrap(), position);
        data[33..41].copy_from_slice(&f64::NAN.to_be_bytes());
        assert!(CursorPosition::decode(&data).is_err());
    }

    #[test]
    fn shapes_check_ihdr_and_retain_exact_samples_and_hotspot() {
        let pixels = [255, 0, 1, 255, 0, 17, 128, 35];
        let image = CursorImage::from_rgba(2, 1, 1.0, 0.5, 0.5, 0.25, &pixels).unwrap();
        let shape = CursorShape { cursor_id: Uuid::from_bytes([0x42; 16]), epoch: 4, revision: 2, image: Some(Arc::new(image)) };
        let mut data = shape.message().unwrap().payload;
        assert_eq!(&data[..4], &[0x43, 0x55, 1, 1]);
        assert_eq!(&data[4..20], &[0x42; 16]);
        assert_eq!(&data[20..37], &[0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 2, 1, 0, 2, 0, 1]);
        assert_eq!(&data[53..61], &0.5f64.to_be_bytes());
        let decoded = CursorShape::decode(&data).unwrap();
        assert_eq!(decoded, shape);
        assert_eq!(decoded.image.unwrap().rgba().unwrap(), pixels);
        data[73 + 16..73 + 20].copy_from_slice(&3u32.to_be_bytes());
        assert!(CursorShape::decode(&data).is_err());
    }

    #[test]
    fn cursor_pixels_accept_palette_transparency_and_grayscale_alpha() {
        let make_png = |color, depth, samples: &[u8]| {
            let mut bytes = Vec::new();
            let mut encoder = png::Encoder::new(&mut bytes, 2, 1);
            encoder.set_color(color);
            encoder.set_depth(depth);
            if color == png::ColorType::Indexed {
                encoder.set_palette(vec![255, 16, 0, 32, 0, 64]);
                encoder.set_trns(vec![0, 127]);
            }
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(samples).unwrap();
            writer.finish().unwrap();
            bytes
        };
        let mut image = CursorImage {
            png: make_png(png::ColorType::Indexed, png::BitDepth::One, &[0x40]),
            pixel_width: 2,
            pixel_height: 1,
            logical_width: 2.0,
            logical_height: 1.0,
            hot_spot_x: 0.0,
            hot_spot_y: 0.0,
        };
        assert_eq!(image.rgba().unwrap(), [255, 16, 0, 0, 32, 0, 64, 127]);
        image.png = make_png(png::ColorType::GrayscaleAlpha, png::BitDepth::Sixteen, &[0x66, 0, 0xff, 0xff, 0, 0, 0x22, 0]);
        assert_eq!(image.rgba().unwrap(), [0x66, 0x66, 0x66, 255, 0, 0, 0, 0x22]);
    }

    #[test]
    fn only_the_displayed_stream_with_a_confirmed_epoch_can_switch_mode() {
        let id = Uuid::new_v4();
        let mut state = CursorPresentationState::default();
        let first = stream(1, 1);
        let second = stream(1, 2);
        let status = |epoch, enabled| CursorControl::status(Uuid::new_v4(), id, epoch, enabled, None);
        assert!(state.bind(&CursorControl::binding(id, 1, true, first)));
        assert!(!state.commit(first));
        assert!(state.status(&status(1, true)));
        assert!(!state.enabled && state.commit(first) && state.enabled);
        let first_position = CursorPosition { cursor_id: id, epoch: 1, sequence: 1, inside_display: true, x: 0.5, y: 0.25 };
        assert!(state.update_position(&first_position));
        assert!(!state.update_position(&first_position));
        let known = CursorShape {
            cursor_id: id,
            epoch: 1,
            revision: 2,
            image: Some(Arc::new(CursorImage::from_rgba(1, 1, 1.0, 1.0, 0.0, 0.0, &[1, 2, 3, 255]).unwrap())),
        };
        assert!(state.update_shape(&known));
        assert!(!state.update_shape(&CursorShape { revision: 1, image: None, ..known.clone() }));
        assert!(state.image.is_some());
        assert!(state.update_shape(&CursorShape { revision: 3, image: None, ..known.clone() }));
        assert!(state.image.is_none() && state.enabled && state.position == Some(first_position));
        assert!(state.bind(&CursorControl::binding(id, 2, false, second)));
        assert!(state.status(&status(2, false)));
        assert!(state.position.is_none() && !state.update_position(&first_position) && state.enabled);
        assert!(!state.update_shape(&known));
        assert!(state.commit(second) && !state.enabled);
        assert_eq!(state.committed_stream(), Some(second));
        assert!(!state.bind(&CursorControl::binding(id, 2, true, first)));
    }

    #[test]
    fn delayed_status_cannot_create_an_unbounded_binding_cache() {
        let mut state = CursorPresentationState::default();
        let id = Uuid::new_v4();
        for epoch in 1..100 {
            assert!(state.bind(&CursorControl::binding(id, 1, true, stream(epoch, epoch))));
        }
        assert!(state.status(&CursorControl::status(Uuid::new_v4(), id, 1, true, None)));
        assert!(!state.commit(stream(1, 1)));
        assert!(state.commit(stream(99, 99)));
    }
}
