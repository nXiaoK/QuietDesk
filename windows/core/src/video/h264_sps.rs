use super::MAXIMUM_PARAMETER_SET_BYTES;

/// Recognizes the limited-range, 8-bit 4:2:0 Display P3 format carried by the macOS encoder.
pub fn h264_sps_is_display_p3(sps: &[u8]) -> bool {
    let Some((&header, payload)) = sps.split_first() else { return false };
    if header & 0x9f != 7 || header & 0x60 == 0 || sps.len() > MAXIMUM_PARAMETER_SET_BYTES {
        return false;
    }
    let mut rbsp = Vec::with_capacity(payload.len());
    let mut zeros = 0;
    for (index, &byte) in payload.iter().enumerate() {
        if zeros == 2 && byte <= 3 {
            if byte != 3 || payload.get(index + 1).is_none_or(|next| *next > 3) {
                return false;
            }
            zeros = 0;
            continue;
        }
        zeros = if byte == 0 { zeros + 1 } else { 0 };
        rbsp.push(byte);
    }
    sequence_parameter_set(&mut Bits { data: &rbsp, offset: 0 }).is_some()
}

struct Bits<'a> {
    data: &'a [u8],
    offset: usize,
}

impl Bits<'_> {
    fn read(&mut self, count: usize) -> Option<u32> {
        let end = self.offset + count;
        if end > self.data.len() * 8 {
            return None;
        }
        let mut value = 0;
        for bit in self.offset..end {
            value = (value << 1) | u32::from((self.data[bit / 8] >> (7 - bit % 8)) & 1);
        }
        self.offset = end;
        Some(value)
    }

    fn flag(&mut self) -> Option<bool> {
        Some(self.read(1)? != 0)
    }

    // Signed Exp-Golomb fields use the same codeword lengths when only skipping them.
    fn golomb(&mut self) -> Option<u32> {
        for zeros in 0..32 {
            if self.flag()? {
                return Some((1 << zeros) - 1 + self.read(zeros)?);
            }
        }
        None
    }

    fn finish(&mut self) -> Option<()> {
        let remaining = self.data.len() * 8 - self.offset;
        if !(1..=8).contains(&remaining) || self.read(remaining)? != 1 << (remaining - 1) {
            return None;
        }
        Some(())
    }
}

// ITU-T H.264 7.3.2.1.1 and Annex E. Follow the SPS and VUI through the trailing bits
// so a truncated parameter set does not supply a display hint.
fn sequence_parameter_set(bits: &mut Bits<'_>) -> Option<()> {
    let profile = bits.read(8)?;
    if bits.read(8)? & 3 != 0 {
        return None;
    }
    bits.read(8)?; // level_idc
    if bits.golomb()? > 31 {
        return None;
    }
    match profile {
        66 | 77 | 88 => {}
        100 => {
            if bits.golomb()? != 1 || bits.golomb()? != 0 || bits.golomb()? != 0 {
                return None;
            }
            bits.flag()?; // qpprime_y_zero_transform_bypass_flag
            if bits.flag()? {
                return None;
            } // The default scaling matrices used by the macOS stream.
        }
        _ => return None,
    }
    if bits.golomb()? > 12 {
        return None;
    } // log2_max_frame_num_minus4
    match bits.golomb()? {
        0 => {
            if bits.golomb()? > 12 {
                return None;
            }
        } // log2_max_pic_order_cnt_lsb_minus4
        1 => {
            bits.flag()?;
            bits.golomb()?;
            bits.golomb()?;
            let offsets = bits.golomb()?;
            if offsets > 255 {
                return None;
            }
            for _ in 0..offsets {
                bits.golomb()?;
            }
        }
        2 => {}
        _ => return None,
    }
    bits.golomb()?; // max_num_ref_frames
    bits.flag()?; // gaps_in_frame_num_value_allowed_flag
    bits.golomb()?; // pic_width_in_mbs_minus1
    bits.golomb()?; // pic_height_in_map_units_minus1
    if !bits.flag()? {
        bits.flag()?;
    } // mb_adaptive_frame_field_flag
    bits.flag()?; // direct_8x8_inference_flag
    if bits.flag()? {
        for _ in 0..4 {
            bits.golomb()?;
        } // frame crop offsets
    }
    if !bits.flag()? {
        return None;
    }
    display_p3_vui(bits)?;
    bits.finish()
}

fn display_p3_vui(bits: &mut Bits<'_>) -> Option<()> {
    if bits.flag()? && bits.read(8)? == 255 {
        bits.read(32)?;
    } // extended sample aspect ratio
    if bits.flag()? {
        bits.flag()?;
    } // overscan_appropriate_flag
    if !bits.flag()? {
        return None;
    } // video_signal_type_present_flag
    bits.read(3)?; // video_format
    if bits.flag()? || !bits.flag()? {
        return None;
    } // limited range and explicit color description
    if [bits.read(8)?, bits.read(8)?, bits.read(8)?] != [12, 13, 1] {
        return None;
    } // P3-D65, sRGB transfer, BT.709 matrix

    if bits.flag()? {
        bits.golomb()?;
        bits.golomb()?;
    } // chroma sample locations
    if bits.flag()? {
        bits.read(32)?;
        bits.read(32)?;
        bits.flag()?;
    } // timing info
    let nal_hrd = bits.flag()?;
    if nal_hrd {
        skip_hrd(bits)?;
    }
    let vcl_hrd = bits.flag()?;
    if vcl_hrd {
        skip_hrd(bits)?;
    }
    if nal_hrd || vcl_hrd {
        bits.flag()?;
    } // low_delay_hrd_flag
    bits.flag()?; // pic_struct_present_flag
    if bits.flag()? {
        bits.flag()?;
        for _ in 0..6 {
            bits.golomb()?;
        } // bitstream restriction fields
    }
    Some(())
}

fn skip_hrd(bits: &mut Bits<'_>) -> Option<()> {
    let buffers_minus_one = bits.golomb()?;
    if buffers_minus_one > 31 {
        return None;
    }
    bits.read(8)?; // bit-rate and coded-picture buffer scales
    for _ in 0..=buffers_minus_one {
        bits.golomb()?;
        bits.golomb()?;
        bits.flag()?;
    }
    bits.read(20)?; // four five-bit delay and time-offset lengths
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_complete_parameter_sets_with_the_p3_vui_supply_a_hint() {
        // The macOS VideoToolbox encoder produced this SPS from a synthetic limited-range P3 color block.
        let p3 = [0x27, 0x64, 0, 0x1e, 0xac, 0x56, 0x80, 0xa0, 0x2f, 0xf9, 0x66, 0xa1, 0x81, 0xa0, 0x20, 0x40];
        let bt709 = [0x27, 0x64, 0, 0x1e, 0xac, 0x56, 0x80, 0xa0, 0x2f, 0xf9, 0x66, 0xa0, 0x20, 0x20, 0x20, 0x40];
        assert!(h264_sps_is_display_p3(&p3));
        assert!(!h264_sps_is_display_p3(&bt709));
        for length in 0..p3.len() {
            assert!(!h264_sps_is_display_p3(&p3[..length]), "truncated at {length} bytes");
        }
    }
}
