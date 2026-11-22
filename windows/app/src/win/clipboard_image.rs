//! Conversion between the clipboard's common packed BGRA bitmap and a bounded PNG.
use quietdesk_core::clipboard::MAX_PNG_BYTES;
use std::io::Cursor;

const V5: usize = 124;

fn raster_size(width: u32, height: u32) -> Option<usize> {
    let size = (width as usize).checked_mul(height as usize)?.checked_mul(4)?;
    (size != 0 && size <= MAX_PNG_BYTES).then_some(size)
}

fn word(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

pub(super) fn dib_to_png(dib: &[u8]) -> Option<Vec<u8>> {
    if dib.len() < V5 || word(dib, 0) != V5 as u32 || dib[12..14] != 1u16.to_le_bytes() {
        return None;
    }
    let width = i32::try_from(word(dib, 4)).ok()? as u32;
    let signed_height = word(dib, 8) as i32;
    let height = signed_height.unsigned_abs();
    let size = raster_size(width, height)?;
    let depth = u16::from_le_bytes(dib[14..16].try_into().ok()?);
    let bitfields = word(dib, 16) == 3;
    let masks = [word(dib, 40), word(dib, 44), word(dib, 48), word(dib, 52)];
    // Packed clipboard DIBs may include a palette or embedded profile between the header and pixels.
    let palette_bytes = (word(dib, 32) as usize).checked_mul(4)?;
    let mut offset = V5.checked_add(palette_bytes)?;
    let profile_len = word(dib, 116) as usize;
    if profile_len != 0 {
        let profile = word(dib, 112) as usize;
        if profile < offset {
            return None;
        }
        if profile == offset {
            offset = offset.checked_add(profile_len)?
        }
    }
    let step = match depth {
        24 if word(dib, 16) == 0 => 3,
        32 if word(dib, 16) == 0 || (bitfields && masks[..3] == [0xff0000, 0xff00, 0xff] && matches!(masks[3], 0 | 0xff000000)) => 4,
        _ => return None,
    };
    let stride = (width as usize * step).next_multiple_of(4);
    let pixels = dib.get(offset..offset.checked_add(stride.checked_mul(height as usize)?)?)?;
    let mut rgba = Vec::with_capacity(size);
    for y in 0..height as usize {
        let row = if signed_height < 0 { y } else { height as usize - 1 - y };
        for p in pixels[row * stride..row * stride + width as usize * step].chunks_exact(step) {
            rgba.extend_from_slice(&[p[2], p[1], p[0], if bitfields && masks[3] != 0 { p[3] } else { 255 }]);
        }
    }
    let mut png = Vec::new();
    let mut encoder = png::Encoder::new(&mut png, width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().ok()?;
    writer.write_image_data(&rgba).ok()?;
    writer.finish().ok()?;
    (png.len() <= MAX_PNG_BYTES).then_some(png)
}

pub(super) fn png_to_dib(png: &[u8]) -> Option<Vec<u8>> {
    let mut decoder = png::Decoder::new_with_limits(Cursor::new(png), png::Limits { bytes: MAX_PNG_BYTES });
    decoder.set_ignore_text_chunk(true);
    decoder.set_ignore_iccp_chunk(true);
    decoder.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
    let mut reader = decoder.read_info().ok()?;
    let (width, height) = (reader.info().width, reader.info().height);
    let size = raster_size(width, height)?;
    let mut pixels = vec![0; reader.output_buffer_size().filter(|s| *s <= size)?];
    let info = reader.next_frame(&mut pixels).ok()?;
    if (info.width, info.height) != (width, height) {
        return None;
    }
    let mut dib = vec![0; V5];
    for (off, val) in [
        (0, V5 as u32),
        (4, width),
        (8, (-(height as i32)) as u32),
        (16, 3),
        (20, size as u32),
        (40, 0xff0000),
        (44, 0xff00),
        (48, 0xff),
        (52, 0xff000000),
        (56, 0x73524742),
    ] {
        dib[off..off + 4].copy_from_slice(&val.to_le_bytes());
    }
    dib[12..14].copy_from_slice(&1u16.to_le_bytes());
    dib[14..16].copy_from_slice(&32u16.to_le_bytes());
    dib.reserve_exact(size);
    let pixels = &pixels[..info.buffer_size()];
    match info.color_type {
        png::ColorType::Rgba => {
            for &[r, g, b, a] in pixels.as_chunks::<4>().0 {
                dib.extend_from_slice(&[b, g, r, a]);
            }
        }
        png::ColorType::GrayscaleAlpha => {
            for &[g, a] in pixels.as_chunks::<2>().0 {
                dib.extend_from_slice(&[g, g, g, a]);
            }
        }
        _ => return None,
    }
    Some(dib)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bottom_up_padded_bgr_and_top_down_alpha_use_same_colors() {
        let mut dib = vec![0; V5];
        for (off, val) in [(0, V5 as u32), (4, 1), (8, 2)] {
            dib[off..off + 4].copy_from_slice(&val.to_le_bytes());
        }
        dib[12] = 1;
        dib[14] = 24;
        dib.extend_from_slice(&[30, 20, 10, 0, 3, 2, 1, 0]);
        let mut out = png_to_dib(&dib_to_png(&dib).unwrap()).unwrap();
        assert_eq!(&out[V5..], &[3, 2, 1, 255, 30, 20, 10, 255]);
        out[V5 + 3] = 96;
        assert_eq!(png_to_dib(&dib_to_png(&out).unwrap()).unwrap(), out);
    }
}
