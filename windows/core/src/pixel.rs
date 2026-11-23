//! Pixel work the Windows roles do in software: scaling and converting captured BGRA frames to the NV12
//! an H.264 encoder takes, converting decoded NV12 back for display, and drawing the pointer into a
//! captured frame. NV12 uses BT.709 coefficients and video range. Tagged Display P3 uses those same
//! coefficients and additionally maps its RGB primaries to the viewer's sRGB output.

use std::sync::OnceLock;
use std::thread;

/// Weights of the source samples that one output sample averages, in 1/4096 units.
struct Span {
    first: usize,
    weights: Vec<u32>,
}

const WEIGHT_SHIFT: u32 = 12;

/// Area-average spans for reducing `source` samples to `target` samples.
fn spans(source: usize, target: usize) -> Vec<Span> {
    let scale = source as f64 / target as f64;
    (0..target)
        .map(|index| {
            let (start, end) = (index as f64 * scale, (index + 1) as f64 * scale);
            let first = start.floor() as usize;
            let last = (end.ceil() as usize).clamp(first + 1, source);
            let mut weights: Vec<u32> = (first..last)
                .map(|sample| {
                    let overlap = (end.min((sample + 1) as f64) - start.max(sample as f64)).max(0.0);
                    (overlap / scale * f64::from(1u32 << WEIGHT_SHIFT)).round() as u32
                })
                .collect();
            // Rounding must not change the brightness: the weights of a span add up to exactly one.
            let total: u32 = weights.iter().sum();
            let largest = weights.iter().enumerate().max_by_key(|(_, weight)| **weight).map(|(position, _)| position).unwrap_or(0);
            weights[largest] = weights[largest] + (1 << WEIGHT_SHIFT) - total;
            Span { first, weights }
        })
        .collect()
}

#[inline]
fn luma(blue: u32, green: u32, red: u32) -> u8 {
    (((47 * red + 157 * green + 16 * blue + 128) >> 8) + 16) as u8
}

#[inline]
fn chroma(blue: i32, green: i32, red: i32) -> (u8, u8) {
    let u = ((-26 * red - 87 * green + 112 * blue + 128) >> 8) + 128;
    let v = ((112 * red - 102 * green - 10 * blue + 128) >> 8) + 128;
    (u.clamp(0, 255) as u8, v.clamp(0, 255) as u8)
}

fn worker_count(rows: usize) -> usize {
    let available = thread::available_parallelism().map_or(1, usize::from);
    // Below a few hundred rows per worker the threads cost more than they save.
    available.min(8).min(rows / 128).max(1)
}

/// Converts frames of one source size to NV12 of one output size.
pub struct Nv12Converter {
    source: (usize, usize),
    target: (usize, usize),
    columns: Vec<Span>,
    rows: Vec<Span>,
}

impl Nv12Converter {
    /// `target` must be even on both axes and no larger than `source`.
    pub fn new(source: (usize, usize), target: (usize, usize)) -> Self {
        assert!(target.0.is_multiple_of(2) && target.1.is_multiple_of(2) && target.0 >= 2 && target.1 >= 2, "NV12 needs even dimensions");
        assert!(target.0 <= source.0 && target.1 <= source.1, "frames are never enlarged");
        Self { source, target, columns: spans(source.0, target.0), rows: spans(source.1, target.1) }
    }

    pub fn target(&self) -> (usize, usize) {
        self.target
    }

    /// Bytes of the output: a luma plane, then interleaved chroma at half resolution, rows packed.
    pub fn output_bytes(&self) -> usize {
        self.target.0 * self.target.1 * 3 / 2
    }

    /// `bgra` holds `source` rows of `stride` bytes; `nv12` holds `output_bytes()`.
    pub fn convert(&self, bgra: &[u8], stride: usize, nv12: &mut [u8]) {
        let (width, height) = self.target;
        assert!(stride >= self.source.0 * 4 && bgra.len() >= stride * (self.source.1 - 1) + self.source.0 * 4, "source frame is too small");
        assert_eq!(nv12.len(), self.output_bytes(), "output frame has the wrong size");
        let (luma_plane, chroma_plane) = nv12.split_at_mut(width * height);
        // Bands hold whole pairs of rows, since each chroma row belongs to two luma rows.
        let band_rows = (height / worker_count(height)).div_ceil(2) * 2;
        thread::scope(|scope| {
            let bands = luma_plane.chunks_mut(band_rows * width).zip(chroma_plane.chunks_mut(band_rows / 2 * width));
            for (band, (luma_band, chroma_band)) in bands.enumerate() {
                scope.spawn(move || self.convert_band(bgra, stride, band * band_rows, luma_band, chroma_band));
            }
        });
    }

    fn convert_band(&self, bgra: &[u8], stride: usize, first_row: usize, luma_band: &mut [u8], chroma_band: &mut [u8]) {
        let width = self.target.0;
        let scaled = self.source != self.target;
        // Each source row is reduced horizontally once, although two neighbouring output rows may share it.
        let mut reduced: Vec<(usize, Vec<u8>)> = Vec::new();
        let mut pair = [vec![0u8; width * 4], vec![0u8; width * 4]];
        for (pair_index, (luma_rows, chroma_row)) in luma_band.chunks_mut(width * 2).zip(chroma_band.chunks_mut(width)).enumerate() {
            let row = first_row + pair_index * 2;
            for (offset, line) in pair.iter_mut().enumerate() {
                if scaled {
                    self.scale_row(bgra, stride, row + offset, &mut reduced, line);
                } else {
                    let start = (row + offset) * stride;
                    line.copy_from_slice(&bgra[start..start + width * 4]);
                }
            }
            let (upper, lower) = luma_rows.split_at_mut(width);
            for (line, output) in pair.iter().zip([upper, lower]) {
                for (pixel, value) in line.as_chunks::<4>().0.iter().zip(output.iter_mut()) {
                    *value = luma(u32::from(pixel[0]), u32::from(pixel[1]), u32::from(pixel[2]));
                }
            }
            for ((upper, lower), output) in pair[0].as_chunks::<8>().0.iter().zip(pair[1].as_chunks::<8>().0).zip(chroma_row.as_chunks_mut::<2>().0) {
                let sum = |channel: usize| {
                    (i32::from(upper[channel]) + i32::from(upper[channel + 4]) + i32::from(lower[channel]) + i32::from(lower[channel + 4]) + 2) >> 2
                };
                let (u, v) = chroma(sum(0), sum(1), sum(2));
                output[0] = u;
                output[1] = v;
            }
        }
    }

    fn scale_row(&self, bgra: &[u8], stride: usize, row: usize, reduced: &mut Vec<(usize, Vec<u8>)>, output: &mut [u8]) {
        let span = &self.rows[row];
        reduced.retain(|(source_row, _)| *source_row >= span.first);
        for source_row in span.first..span.first + span.weights.len() {
            if reduced.iter().any(|(cached, _)| *cached == source_row) {
                continue;
            }
            let source = &bgra[source_row * stride..source_row * stride + self.source.0 * 4];
            let mut line = vec![0u8; self.target.0 * 4];
            for (column, pixel) in self.columns.iter().zip(line.as_chunks_mut::<4>().0) {
                let mut sums = [1u32 << (WEIGHT_SHIFT - 1); 3];
                for (weight, sample) in column.weights.iter().zip(source[column.first * 4..].as_chunks::<4>().0) {
                    for channel in 0..3 {
                        sums[channel] += weight * u32::from(sample[channel]);
                    }
                }
                for channel in 0..3 {
                    pixel[channel] = (sums[channel] >> WEIGHT_SHIFT) as u8;
                }
            }
            reduced.push((source_row, line));
        }
        let mut sums = vec![1u32 << (WEIGHT_SHIFT - 1); self.target.0 * 4];
        for (weight, source_row) in span.weights.iter().zip(span.first..) {
            let line = &reduced.iter().find(|(cached, _)| *cached == source_row).expect("row was reduced above").1;
            for (sum, sample) in sums.iter_mut().zip(line) {
                *sum += weight * u32::from(*sample);
            }
        }
        for (value, sum) in output.iter_mut().zip(sums) {
            *value = (sum >> WEIGHT_SHIFT) as u8;
        }
    }
}

/// One plane of a decoded frame.
#[derive(Clone, Copy)]
pub struct Plane<'a> {
    pub data: &'a [u8],
    pub stride: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Nv12Color {
    #[default]
    Bt709,
    DisplayP3,
}

const LINEAR_LEVELS: usize = 4096;
const LINEAR_FRACTION_BITS: u32 = 8;
const LINEAR_FRACTION: i32 = 1 << LINEAR_FRACTION_BITS;

struct DisplayP3ToSrgb {
    red: [[i32; 3]; 256],
    green: [[i32; 3]; 256],
    blue: [i32; 256],
    encoded: [u8; LINEAR_LEVELS],
}

impl DisplayP3ToSrgb {
    fn shared() -> &'static Self {
        static CONVERSION: OnceLock<DisplayP3ToSrgb> = OnceLock::new();
        CONVERSION.get_or_init(|| {
            let linear: [f64; 256] = std::array::from_fn(|code| {
                let value = code as f64 / 255.0;
                if value <= 0.04045 { value / 12.92 } else { ((value + 0.055) / 1.055).powf(2.4) }
            });
            let contribution = |value: f64, coefficient: f64| (value * coefficient * (LINEAR_LEVELS - 1) as f64 * f64::from(LINEAR_FRACTION)).round() as i32;
            // CSS Color 4: linear Display P3 -> XYZ (D65) -> linear sRGB. The two
            // linear matrices are combined and tabulated by input channel.
            Self {
                red: linear.map(|value| [1.224_940_176, -0.042_056_955, -0.019_637_555].map(|c| contribution(value, c))),
                green: linear.map(|value| [-0.224_940_176, 1.042_056_955, -0.078_636_046].map(|c| contribution(value, c))),
                blue: linear.map(|value| contribution(value, 1.098_273_600)),
                encoded: std::array::from_fn(|code| {
                    let value = code as f64 / (LINEAR_LEVELS - 1) as f64;
                    let srgb = if value <= 0.0031308 { 12.92 * value } else { 1.055 * value.powf(1.0 / 2.4) - 0.055 };
                    (srgb * 255.0).round() as u8
                }),
            }
        })
    }

    #[inline]
    fn convert(&self, [blue, green, red]: [u8; 3]) -> [u8; 3] {
        let r = self.red[usize::from(red)];
        let g = self.green[usize::from(green)];
        let encode = |value: i32| {
            let level = ((value + LINEAR_FRACTION / 2) >> LINEAR_FRACTION_BITS).clamp(0, (LINEAR_LEVELS - 1) as i32);
            self.encoded[level as usize]
        };
        [encode(r[2] + g[2] + self.blue[usize::from(blue)]), encode(r[1] + g[1]), encode(r[0] + g[0])]
    }
}

/// Converts a decoded NV12 picture to BGRA rows of `width * 4` bytes with opaque alpha.
pub fn nv12_to_bgra(luma_plane: Plane, chroma_plane: Plane, width: usize, height: usize, color: Nv12Color, bgra: &mut [u8]) {
    assert!(width.is_multiple_of(2) && height.is_multiple_of(2), "NV12 needs even dimensions");
    assert!(luma_plane.stride >= width && luma_plane.data.len() >= luma_plane.stride * (height - 1) + width, "luma plane is too small");
    assert!(chroma_plane.stride >= width && chroma_plane.data.len() >= chroma_plane.stride * (height / 2 - 1) + width, "chroma plane is too small");
    assert_eq!(bgra.len(), width * height * 4, "output frame has the wrong size");
    match color {
        Nv12Color::Bt709 => convert_nv12(luma_plane, chroma_plane, width, height, bgra, |pixel| pixel),
        Nv12Color::DisplayP3 => {
            let conversion = DisplayP3ToSrgb::shared();
            convert_nv12(luma_plane, chroma_plane, width, height, bgra, |pixel| conversion.convert(pixel));
        }
    }
}

fn convert_nv12(luma_plane: Plane, chroma_plane: Plane, width: usize, height: usize, bgra: &mut [u8], map_rgb: impl Fn([u8; 3]) -> [u8; 3] + Sync) {
    let band_rows = (height / worker_count(height)).div_ceil(2) * 2;
    let map_rgb = &map_rgb;
    thread::scope(|scope| {
        for (band, output) in bgra.chunks_mut(band_rows * width * 4).enumerate() {
            scope.spawn(move || {
                for (offset, line) in output.chunks_exact_mut(width * 4).enumerate() {
                    let row = band * band_rows + offset;
                    let luma_row = &luma_plane.data[row * luma_plane.stride..][..width];
                    let chroma_row = &chroma_plane.data[row / 2 * chroma_plane.stride..][..width];
                    for ((pixels, luma_pair), chroma_pair) in
                        line.as_chunks_mut::<8>().0.iter_mut().zip(luma_row.as_chunks::<2>().0).zip(chroma_row.as_chunks::<2>().0)
                    {
                        let (d, e) = (i32::from(chroma_pair[0]) - 128, i32::from(chroma_pair[1]) - 128);
                        let (red, green, blue) = (459 * e + 128, -55 * d - 136 * e + 128, 541 * d + 128);
                        for (pixel, value) in pixels.as_chunks_mut::<4>().0.iter_mut().zip(luma_pair) {
                            let c = 298 * (i32::from(*value) - 16);
                            let [b, g, r] = map_rgb([blue, green, red].map(|component| ((c + component) >> 8).clamp(0, 255) as u8));
                            *pixel = [b, g, r, 255];
                        }
                    }
                }
            });
        }
    });
}

/// How the bytes of a pointer shape combine with the screen, as desktop duplication reports them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PointerKind {
    /// 32-bit colour with straight alpha.
    Color,
    /// 32-bit colour whose alpha byte selects replace (0) or exclusive-or (255).
    MaskedColor,
    /// A 1-bit AND mask above a 1-bit XOR mask.
    Monochrome,
}

#[derive(Clone, Debug)]
pub struct PointerShape {
    pub kind: PointerKind,
    pub width: usize,
    /// Rows drawn on screen; a monochrome shape stores twice as many.
    pub height: usize,
    pub pitch: usize,
    pub data: Vec<u8>,
}

impl PointerShape {
    /// Whether the buffer holds every row its dimensions promise.
    pub fn is_complete(&self) -> bool {
        let (rows, row_bytes) = match self.kind {
            PointerKind::Monochrome => (self.height * 2, self.width.div_ceil(8)),
            PointerKind::Color | PointerKind::MaskedColor => (self.height, self.width * 4),
        };
        self.width > 0 && self.height > 0 && self.pitch >= row_bytes && self.data.len() >= self.pitch * (rows - 1) + row_bytes
    }
}

/// The frame pixels a pointer was drawn over, to put back before the next capture is converted.
pub struct PointerPatch {
    left: usize,
    top: usize,
    width: usize,
    rows: Vec<u8>,
}

impl PointerPatch {
    pub fn restore(self, frame: &mut [u8], stride: usize) {
        for (offset, row) in self.rows.chunks_exact(self.width * 4).enumerate() {
            let start = (self.top + offset) * stride + self.left * 4;
            frame[start..start + row.len()].copy_from_slice(row);
        }
    }
}

/// Draws a complete pointer shape with its top-left corner at (`x`, `y`), clipped to the frame.
pub fn draw_pointer(frame: &mut [u8], stride: usize, size: (usize, usize), shape: &PointerShape, x: i32, y: i32) -> Option<PointerPatch> {
    let clip = |position: i32, extent: usize, limit: usize| {
        let start = position.max(0) as usize;
        let end = (i64::from(position) + extent as i64).clamp(0, limit as i64) as usize;
        (start < end).then_some((start, end))
    };
    let (left, right) = clip(x, shape.width, size.0)?;
    let (top, bottom) = clip(y, shape.height, size.1)?;
    let width = right - left;
    let mut rows = Vec::with_capacity(width * 4 * (bottom - top));
    for row in top..bottom {
        let line = &mut frame[row * stride + left * 4..][..width * 4];
        rows.extend_from_slice(line);
        let shape_row = (row as i32 - y) as usize;
        for (offset, pixel) in line.as_chunks_mut::<4>().0.iter_mut().enumerate() {
            let shape_column = ((left + offset) as i32 - x) as usize;
            match shape.kind {
                PointerKind::Color => {
                    let source = &shape.data[shape_row * shape.pitch + shape_column * 4..][..4];
                    let alpha = u32::from(source[3]);
                    for channel in 0..3 {
                        pixel[channel] = ((u32::from(source[channel]) * alpha + u32::from(pixel[channel]) * (255 - alpha) + 127) / 255) as u8;
                    }
                }
                PointerKind::MaskedColor => {
                    let source = &shape.data[shape_row * shape.pitch + shape_column * 4..][..4];
                    for channel in 0..3 {
                        pixel[channel] = if source[3] == 0 { source[channel] } else { pixel[channel] ^ source[channel] };
                    }
                }
                PointerKind::Monochrome => {
                    let bit = |row: usize| shape.data[row * shape.pitch + shape_column / 8] & (0x80 >> (shape_column % 8)) != 0;
                    let (and, xor) = (bit(shape_row), bit(shape_row + shape.height));
                    for value in &mut pixel[..3] {
                        *value = match (and, xor) {
                            (false, false) => 0,
                            (false, true) => 255,
                            (true, false) => *value,
                            (true, true) => !*value,
                        };
                    }
                }
            }
        }
    }
    Some(PointerPatch { left, top, width, rows })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pattern(width: usize, height: usize, stride: usize) -> Vec<u8> {
        let mut frame = vec![0u8; stride * height];
        for row in 0..height {
            for column in 0..width {
                let pixel = &mut frame[row * stride + column * 4..][..4];
                pixel[0] = (column * 7 + row * 3) as u8;
                pixel[1] = ((column * 5) ^ (row * 11)) as u8;
                pixel[2] = (column + row * 13) as u8;
                pixel[3] = 255;
            }
        }
        frame
    }

    /// The same conversion in floating point: area average, then BT.709 video range.
    fn reference(frame: &[u8], stride: usize, source: (usize, usize), target: (usize, usize)) -> Vec<u8> {
        let (scale_x, scale_y) = (source.0 as f64 / target.0 as f64, source.1 as f64 / target.1 as f64);
        let average = |column: usize, row: usize, channel: usize| {
            let (x0, x1, y0, y1) = (column as f64 * scale_x, (column + 1) as f64 * scale_x, row as f64 * scale_y, (row + 1) as f64 * scale_y);
            let mut sum = 0.0;
            for y in y0.floor() as usize..(y1.ceil() as usize).min(source.1) {
                for x in x0.floor() as usize..(x1.ceil() as usize).min(source.0) {
                    let weight = (x1.min((x + 1) as f64) - x0.max(x as f64)).max(0.0) * (y1.min((y + 1) as f64) - y0.max(y as f64)).max(0.0);
                    sum += weight * f64::from(frame[y * stride + x * 4 + channel]);
                }
            }
            sum / (scale_x * scale_y)
        };
        let mut output = vec![0u8; target.0 * target.1 * 3 / 2];
        for row in 0..target.1 {
            for column in 0..target.0 {
                let (b, g, r) = (average(column, row, 0), average(column, row, 1), average(column, row, 2));
                output[row * target.0 + column] = (16.0 + 0.1826 * r + 0.6142 * g + 0.0620 * b).round() as u8;
            }
        }
        for row in 0..target.1 / 2 {
            for column in 0..target.0 / 2 {
                let mean = |channel: usize| (0..4).map(|corner| average(column * 2 + corner % 2, row * 2 + corner / 2, channel)).sum::<f64>() / 4.0;
                let (b, g, r) = (mean(0), mean(1), mean(2));
                let base = target.0 * target.1 + row * target.0 + column * 2;
                output[base] = (128.0 - 0.1006 * r - 0.3386 * g + 0.4392 * b).round() as u8;
                output[base + 1] = (128.0 + 0.4392 * r - 0.3989 * g - 0.0403 * b).round() as u8;
            }
        }
        output
    }

    fn largest_difference(left: &[u8], right: &[u8]) -> i32 {
        left.iter().zip(right).map(|(a, b)| (i32::from(*a) - i32::from(*b)).abs()).max().unwrap()
    }

    #[test]
    fn conversion_matches_a_floating_point_reference_at_several_scales() {
        for (source, target) in [((64, 48), (64, 48)), ((64, 48), (32, 24)), ((96, 54), (64, 36)), ((101, 67), (38, 26)), ((640, 400), (638, 398))] {
            let stride = source.0 * 4 + 12;
            let frame = pattern(source.0, source.1, stride);
            let converter = Nv12Converter::new(source, target);
            let mut output = vec![0u8; converter.output_bytes()];
            converter.convert(&frame, stride, &mut output);
            let difference = largest_difference(&output, &reference(&frame, stride, source, target));
            assert!(difference <= 2, "{source:?} to {target:?} differs by {difference}");
        }
    }

    #[test]
    fn flat_colours_keep_their_video_range_levels_at_any_scale() {
        for (colour, expected) in [([255u8, 255, 255, 255], (235, 128, 128)), ([0, 0, 0, 255], (16, 128, 128)), ([0, 0, 255, 255], (63, 102, 240))] {
            let frame: Vec<u8> = colour.iter().copied().cycle().take(300 * 200 * 4).collect();
            let converter = Nv12Converter::new((300, 200), (130, 86));
            let mut output = vec![0u8; converter.output_bytes()];
            converter.convert(&frame, 300 * 4, &mut output);
            let (luma, chroma) = output.split_at(130 * 86);
            assert!(luma.iter().all(|value| (i32::from(*value) - expected.0).abs() <= 1), "{colour:?}");
            assert!(chroma.chunks(2).all(|pair| (i32::from(pair[0]) - expected.1).abs() <= 1 && (i32::from(pair[1]) - expected.2).abs() <= 1), "{colour:?}");
        }
    }

    #[test]
    fn tall_frames_convert_identically_with_and_without_worker_bands() {
        let source = (64, 1200);
        let frame = pattern(source.0, source.1, source.0 * 4);
        let converter = Nv12Converter::new(source, (32, 600));
        let mut whole = vec![0u8; converter.output_bytes()];
        converter.convert(&frame, source.0 * 4, &mut whole);
        let (luma, chroma) = whole.split_at(32 * 600);
        let mut single = vec![0u8; converter.output_bytes()];
        let (single_luma, single_chroma) = single.split_at_mut(32 * 600);
        converter.convert_band(&frame, source.0 * 4, 0, single_luma, single_chroma);
        assert!(luma == single_luma && chroma == single_chroma);
    }

    #[test]
    fn decoded_pictures_return_to_the_colours_that_were_encoded() {
        let (width, height) = (64, 36);
        let frame = pattern(width, height, width * 4);
        // Chroma is shared by four pixels, so only flat 2x2 blocks survive a round trip exactly.
        let mut blocks = frame.clone();
        for row in 0..height {
            for column in 0..width {
                let source = (row / 2 * 2) * width * 4 + (column / 2 * 2) * 4;
                let pixel: [u8; 4] = frame[source..source + 4].try_into().unwrap();
                blocks[row * width * 4 + column * 4..][..4].copy_from_slice(&pixel);
            }
        }
        let converter = Nv12Converter::new((width, height), (width, height));
        let mut nv12 = vec![0u8; converter.output_bytes()];
        converter.convert(&blocks, width * 4, &mut nv12);
        // Decoders hand out planes with padding; the stride is not the width.
        let stride = width + 16;
        let mut padded_luma = vec![0u8; stride * height];
        let mut padded_chroma = vec![0u8; stride * height / 2];
        for row in 0..height {
            padded_luma[row * stride..][..width].copy_from_slice(&nv12[row * width..][..width]);
        }
        for row in 0..height / 2 {
            padded_chroma[row * stride..][..width].copy_from_slice(&nv12[width * height + row * width..][..width]);
        }
        let mut decoded = vec![0u8; width * height * 4];
        nv12_to_bgra(Plane { data: &padded_luma, stride }, Plane { data: &padded_chroma, stride }, width, height, Nv12Color::Bt709, &mut decoded);
        assert!(largest_difference(&decoded, &blocks) <= 4);
        assert!(decoded.chunks(4).all(|pixel| pixel[3] == 255));
    }

    #[test]
    fn tagged_display_p3_maps_colors_to_srgb_and_keeps_neutral_gray() {
        let luma = Plane { data: &[124, 124, 120, 120, 126, 126, 124, 124, 120, 120, 126, 126], stride: 6 };
        let chroma = Plane { data: &[88, 184, 96, 180, 128, 128], stride: 6 };
        let mut frame = [0; 6 * 2 * 4];
        nv12_to_bgra(luma, chroma, 6, 2, Nv12Color::DisplayP3, &mut frame);
        let expected = [[0, 95, 244, 255], [35, 91, 231, 255], [128, 128, 128, 255]];
        for (index, pixel) in frame.chunks_exact(4).enumerate() {
            assert!(largest_difference(pixel, &expected[index % 6 / 2]) <= 2, "pixel {index}: {pixel:?}");
        }
    }

    #[test]
    fn pointer_kinds_combine_with_the_frame_and_the_patch_puts_it_back() {
        let size = (8, 6);
        let original = pattern(size.0, size.1, size.0 * 4);
        let draw = |shape: &PointerShape, x: i32, y: i32| {
            let mut frame = original.clone();
            let patch = draw_pointer(&mut frame, size.0 * 4, size, shape, x, y);
            let drawn = frame.clone();
            if let Some(patch) = patch {
                patch.restore(&mut frame, size.0 * 4);
            }
            assert_eq!(frame, original);
            drawn
        };
        let pixel = |frame: &[u8], column: usize, row: usize| -> [u8; 3] { frame[row * size.0 * 4 + column * 4..][..3].try_into().unwrap() };

        // Two pixels: opaque red, then half-transparent white.
        let colour = PointerShape { kind: PointerKind::Color, width: 2, height: 1, pitch: 8, data: vec![0, 0, 255, 255, 255, 255, 255, 128] };
        let drawn = draw(&colour, 3, 2);
        assert_eq!(pixel(&drawn, 3, 2), [0, 0, 255]);
        let (before, after) = (pixel(&original, 4, 2), pixel(&drawn, 4, 2));
        for channel in 0..3 {
            let expected = (255 * 128 + u32::from(before[channel]) * 127 + 127) / 255;
            assert_eq!(u32::from(after[channel]), expected);
        }
        assert_eq!(pixel(&drawn, 5, 2), pixel(&original, 5, 2));

        let masked = PointerShape { kind: PointerKind::MaskedColor, width: 2, height: 1, pitch: 8, data: vec![1, 2, 3, 0, 255, 255, 255, 255] };
        let drawn = draw(&masked, 0, 0);
        assert_eq!(pixel(&drawn, 0, 0), [1, 2, 3]);
        assert_eq!(pixel(&drawn, 1, 0), pixel(&original, 1, 0).map(|value| !value));

        // Four pixels in one row: black, white, transparent, inverted.
        let monochrome = PointerShape { kind: PointerKind::Monochrome, width: 4, height: 1, pitch: 1, data: vec![0b0011_0000, 0b0101_0000] };
        let drawn = draw(&monochrome, 2, 5);
        assert_eq!(pixel(&drawn, 2, 5), [0, 0, 0]);
        assert_eq!(pixel(&drawn, 3, 5), [255, 255, 255]);
        assert_eq!(pixel(&drawn, 4, 5), pixel(&original, 4, 5));
        assert_eq!(pixel(&drawn, 5, 5), pixel(&original, 5, 5).map(|value| !value));

        // Clipped at the left and top edges, the visible part still comes from the right shape pixels.
        let drawn = draw(&colour, -1, 0);
        assert_eq!(pixel(&drawn, 0, 0)[2], ((255 * 128 + u32::from(pixel(&original, 0, 0)[2]) * 127 + 127) / 255) as u8);
        assert_eq!(draw(&colour, 8, 0), original);
        assert_eq!(draw(&colour, 0, -1), original);
    }

    #[test]
    fn incomplete_pointer_shapes_are_recognised() {
        let mut shape = PointerShape { kind: PointerKind::Color, width: 2, height: 2, pitch: 8, data: vec![0; 16] };
        assert!(shape.is_complete());
        shape.data.truncate(15);
        assert!(!shape.is_complete());
        let monochrome = PointerShape { kind: PointerKind::Monochrome, width: 9, height: 2, pitch: 2, data: vec![0; 8] };
        assert!(monochrome.is_complete());
        assert!(!PointerShape { height: 3, ..monochrome }.is_complete());
    }
}
